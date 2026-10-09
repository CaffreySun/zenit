#include "d3d12_resources.h"
#include <windows.h>
#include <d3dcompiler.h>
#include <d3d12shader.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "d3d12_warp_shader.h"
struct ZenitD12Shader { ID3DBlob *code; LONG refs; char entry[96]; };
extern "C" const char *zenit_d12_shader_entry(ZenitD12Shader *shader) { return shader->entry; }
#ifdef ZENIT_D12_TEST
static LONG live_shaders;
extern "C" long zenit_d12_test_live_shaders() { return InterlockedCompareExchange(&live_shaders, 0, 0); }
#endif
// ── DXBC disk cache ───────────────────────────────────────────────────────
// D3DCompile of the runtime HLSL is the one-time cost behind "the first glass
// story takes two seconds" (glass.hlsl alone ~1.9 s on a GTX 1650 box). The
// bytecode only depends on the source text, entry, profile and compile flags,
// so it is kept under %LOCALAPPDATA%\zenit\shader-cache keyed by a hash of
// exactly those (plus a format tag to drop stale entries when flags change).
// ZENIT_SHADER_CACHE_DIR overrides the directory; ZENIT_SHADER_CACHE=0 disables.
// A corrupt or truncated entry is ignored and recompiled; writes go through a
// private temp file and MoveFileEx, so readers never see a partial blob.
static const UINT kCompileFlags = D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3;
// Bumping the tag drops every old entry; the flags and the compiler header
// version are hashed as well, so changing either invalidates by itself.
static const char *const kCacheTag = "dxbc-v2|5_1";
// Entry layout: 16-byte header {magic "ZDXC", payload size, FNV-1a 64 of the
// payload} then the DXBC. A header mismatch (truncated by a crash before the
// data reached disk, partial overwrite, foreign file) means recompile; a
// blob that passed D3DCompile is never served from a corrupt file, which
// would otherwise fail PSO creation and trip the sticky "glass pipeline
// failed" flag for the whole session.
struct CacheHeader { char magic[4]; uint32_t size; uint64_t checksum; };
static uint64_t fnv64(const void *data, size_t size) {
    uint64_t h = 1469598103934665603ULL;
    const unsigned char *p = (const unsigned char *)data;
    for (size_t i = 0; i < size; ++i) h = (h ^ p[i]) * 1099511628211ULL;
    return h;
}
static void cache_hash(const void *source, size_t source_size, const char *entry, const char *profile, char out[33]) {
    // Two independent FNV-1a 64 lanes over the same stream: 128 bits is far
    // beyond collision concern for a per-user cache of a few dozen shaders.
    uint64_t a = 1469598103934665603ULL, b = 0x9E3779B97F4A7C15ULL;
    auto feed = [&](const void *data, size_t size) {
        const unsigned char *p = (const unsigned char *)data;
        for (size_t i = 0; i < size; ++i) {
            a = (a ^ p[i]) * 1099511628211ULL;
            b = (b ^ (p[i] + 0x9E)) * 0x100000001B3ULL;
        }
        a = (a ^ 0x1F) * 1099511628211ULL; b = (b ^ 0x2E) * 0x100000001B3ULL; // field separator
    };
    const uint32_t flags = kCompileFlags, compiler = D3D_COMPILER_VERSION;
    feed(kCacheTag, strlen(kCacheTag)); feed(&flags, sizeof flags); feed(&compiler, sizeof compiler);
    feed(source, source_size); feed(entry, strlen(entry)); feed(profile, strlen(profile));
    snprintf(out, 33, "%016llx%016llx", (unsigned long long)a, (unsigned long long)b);
}
static bool cache_path(const char hash[33], wchar_t out[MAX_PATH]) {
    wchar_t dir[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"ZENIT_SHADER_CACHE", dir, MAX_PATH);
    if (n == 1 && dir[0] == L'0') return false;
    n = GetEnvironmentVariableW(L"ZENIT_SHADER_CACHE_DIR", dir, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) {
        n = GetEnvironmentVariableW(L"LOCALAPPDATA", dir, MAX_PATH);
        if (n == 0 || n >= MAX_PATH - 20) return false;
        wcscat(dir, L"\\zenit");
        CreateDirectoryW(dir, nullptr);
        wcscat(dir, L"\\shader-cache");
    }
    CreateDirectoryW(dir, nullptr);
    wchar_t name[48];
    for (int i = 0; i < 32; ++i) name[i] = (wchar_t)hash[i];
    name[32] = 0;
    if (wcslen(dir) + 40 >= MAX_PATH) return false;
    swprintf(out, MAX_PATH, L"%s\\%s.dxbc", dir, name);
    return true;
}
static ID3DBlob *cache_load(const wchar_t *path) {
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return nullptr;
    LARGE_INTEGER size = {};
    ID3DBlob *blob = nullptr;
    CacheHeader header = {};
    DWORD read = 0;
    bool ok = GetFileSizeEx(file, &size) && size.QuadPart > (LONGLONG)sizeof header && size.QuadPart < (64 << 20) &&
        ReadFile(file, &header, sizeof header, &read, nullptr) && read == sizeof header &&
        memcmp(header.magic, "ZDXC", 4) == 0 && header.size == (uint64_t)size.QuadPart - sizeof header && header.size > 4;
    if (ok && SUCCEEDED(D3DCreateBlob(header.size, &blob))) {
        const char *bytes = (const char *)blob->GetBufferPointer();
        if (!ReadFile(file, blob->GetBufferPointer(), header.size, &read, nullptr) || read != header.size ||
            memcmp(bytes, "DXBC", 4) != 0 || fnv64(bytes, header.size) != header.checksum) {
            blob->Release(); blob = nullptr;
        }
    }
    CloseHandle(file);
    if (!blob) DeleteFileW(path); // a bad entry is never retried: recompile and rewrite
    return blob;
}
static void cache_store(const wchar_t *path, ID3DBlob *code) {
    wchar_t tmp[MAX_PATH + 32];
    swprintf(tmp, MAX_PATH + 32, L"%s.%lu.%lu.tmp", path, (unsigned long)GetCurrentProcessId(), (unsigned long)GetCurrentThreadId());
    HANDLE file = CreateFileW(tmp, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    CacheHeader header = {{'Z', 'D', 'X', 'C'}, (uint32_t)code->GetBufferSize(), fnv64(code->GetBufferPointer(), code->GetBufferSize())};
    DWORD written = 0;
    bool ok = WriteFile(file, &header, sizeof header, &written, nullptr) && written == sizeof header &&
        WriteFile(file, code->GetBufferPointer(), (DWORD)code->GetBufferSize(), &written, nullptr) && written == code->GetBufferSize() &&
        FlushFileBuffers(file); // data reaches disk before the rename makes it visible
    CloseHandle(file);
    if (!ok || !MoveFileExW(tmp, path, MOVEFILE_REPLACE_EXISTING)) DeleteFileW(tmp);
}
// In-flight compiles by cache key: the startup warm-up thread and a first
// glass frame asking for the same shader must not both run the 2 s compile.
// The second caller waits for the first and then takes the cache hit.
static SRWLOCK inflight_lock = SRWLOCK_INIT;
static CONDITION_VARIABLE inflight_done = CONDITION_VARIABLE_INIT;
static char inflight[16][33];
static int inflight_find(const char hash[33]) {
    for (int i = 0; i < 16; ++i) if (memcmp(inflight[i], hash, 32) == 0) return i;
    return -1;
}
// Returns true when this caller owns the compile; false when the entry was
// produced by another thread meanwhile (reload from the cache). Capacity
// exhaustion just compiles redundantly.
static bool inflight_claim(const char hash[33]) {
    AcquireSRWLockExclusive(&inflight_lock);
    bool waited = false;
    while (inflight_find(hash) >= 0) { SleepConditionVariableSRW(&inflight_done, &inflight_lock, INFINITE, 0); waited = true; }
    if (!waited) {
        for (int i = 0; i < 16; ++i) if (inflight[i][0] == 0) { memcpy(inflight[i], hash, 33); break; }
    }
    ReleaseSRWLockExclusive(&inflight_lock);
    return !waited;
}
static void inflight_release(const char hash[33]) {
    AcquireSRWLockExclusive(&inflight_lock);
    int i = inflight_find(hash);
    if (i >= 0) inflight[i][0] = 0;
    ReleaseSRWLockExclusive(&inflight_lock);
    WakeAllConditionVariable(&inflight_done);
}
extern "C" int zenit_d12_shader_compile(const void *source, size_t source_size, const char *entry,
    uint32_t stage, ZenitD12Shader **out, char **diagnostic, size_t *diagnostic_size) {
    if (!out || !diagnostic || !diagnostic_size) return 1;
    *out = nullptr; *diagnostic = nullptr; *diagnostic_size = 0;
    if (!source || !source_size || !entry || !*entry || stage < 1 || stage > 3) return 1;
    const char *profile = stage == 1 ? "vs_5_1" : stage == 2 ? "ps_5_1" : "cs_5_1";
    char hash[33]; wchar_t path[MAX_PATH];
    cache_hash(source, source_size, entry, profile, hash);
    const bool cacheable = cache_path(hash, path);
    ID3DBlob *code = cacheable ? cache_load(path) : nullptr, *messages = nullptr;
    HRESULT hr = S_OK;
    bool compiled = false;
    while (!code && !compiled) {
        if (cacheable && !inflight_claim(hash)) {
            // Another thread finished this entry; take it, or become the next
            // owner when its compile or store failed (no concurrent recompile).
            code = cache_load(path);
            continue;
        }
        // Includes are disabled. Never read files relative to the process cwd.
        hr = D3DCompile(source, source_size, entry, nullptr, nullptr, entry, profile, kCompileFlags, 0, &code, &messages);
        compiled = true;
        if (cacheable) {
            if (SUCCEEDED(hr) && code) cache_store(path, code);
            inflight_release(hash);
        }
    }
    if (messages) {
        size_t size = messages->GetBufferSize();
        const char *text = (const char *)messages->GetBufferPointer();
        if (size && text[size - 1] == 0) --size;
        if (size) {
            *diagnostic = (char *)malloc(size);
            if (!*diagnostic) { messages->Release(); if (code) code->Release(); return 2; }
            memcpy(*diagnostic, text, size); *diagnostic_size = size;
        }
        messages->Release();
    }
    if (FAILED(hr)) { if (code) code->Release(); return 3; }
    if (!code) return 2;
    auto shader = (ZenitD12Shader *)calloc(1, sizeof(ZenitD12Shader));
    if (!shader) { code->Release(); return 2; }
#ifdef ZENIT_D12_TEST
    InterlockedIncrement(&live_shaders);
#endif
    strncpy(shader->entry, entry, sizeof(shader->entry)-1);
    shader->code = code; shader->refs = 1; *out = shader; return 0;
}
extern "C" void zenit_d12_shader_retain(ZenitD12Shader *shader) { InterlockedIncrement(&shader->refs); }
extern "C" void zenit_d12_shader_release(ZenitD12Shader *shader) {
    if (!shader || InterlockedDecrement(&shader->refs) != 0) return;
    shader->code->Release(); free(shader);
#ifdef ZENIT_D12_TEST
    InterlockedDecrement(&live_shaders);
#endif
}
extern "C" const void *zenit_d12_shader_data(ZenitD12Shader *shader) { return shader->code->GetBufferPointer(); }
extern "C" size_t zenit_d12_shader_size(ZenitD12Shader *shader) { return shader->code->GetBufferSize(); }
extern "C" void zenit_d12_shader_diagnostic_free(char *diagnostic) { free(diagnostic); }

extern "C" int zenit_d12_shader_bindings(ZenitD12Shader *shader, ZenitD12ShaderBinding *out,
    uint32_t capacity, uint32_t *count) {
    if (!shader || !count || (capacity && !out)) return 1;
    *count=0;
    ID3D12ShaderReflection *reflection=nullptr;
    if (FAILED(D3DReflect(shader->code->GetBufferPointer(),shader->code->GetBufferSize(),IID_ID3D12ShaderReflection,(void **)&reflection))) return 2;
    D3D12_SHADER_DESC desc={};
    if (FAILED(reflection->GetDesc(&desc))) { reflection->Release(); return 2; }
    *count=desc.BoundResources;
    if (!capacity) { reflection->Release(); return 0; }
    if (capacity<desc.BoundResources) { reflection->Release(); return 1; }
    int status=0;
    for (uint32_t i=0;i<desc.BoundResources;++i) {
        D3D12_SHADER_INPUT_BIND_DESC resource={};
        if (FAILED(reflection->GetResourceBindingDesc(i,&resource))) { status=2; break; }
        if (!resource.BindCount || resource.BindCount==UINT32_MAX) { status=3; break; }
        auto &b=out[i]; b={}; b.group=resource.Space; b.binding=resource.BindPoint; b.count=resource.BindCount;
        switch (resource.Type) {
        case D3D_SIT_CBUFFER: {
            b.kind=0; D3D12_SHADER_BUFFER_DESC buffer={};
            if (FAILED(reflection->GetConstantBufferByName(resource.Name)->GetDesc(&buffer))) { status=2; }
            b.min_size=buffer.Size; break;
        }
        case D3D_SIT_TEXTURE:
            b.kind=1;
            switch (resource.Dimension) {
            case D3D_SRV_DIMENSION_TEXTURE1D: b.dimension=1; break;
            case D3D_SRV_DIMENSION_TEXTURE2D: b.dimension=2; break;
            case D3D_SRV_DIMENSION_TEXTURE2DARRAY: b.dimension=3; break;
            case D3D_SRV_DIMENSION_TEXTURECUBE: b.dimension=4; break;
            case D3D_SRV_DIMENSION_TEXTURECUBEARRAY: b.dimension=5; break;
            case D3D_SRV_DIMENSION_TEXTURE3D: b.dimension=6; break;
            default: status=3; break;
            }
            switch (resource.ReturnType) {
            case D3D_RETURN_TYPE_FLOAT: case D3D_RETURN_TYPE_UNORM: case D3D_RETURN_TYPE_SNORM: b.sample_type=1; break;
            case D3D_RETURN_TYPE_SINT: b.sample_type=4; break;
            case D3D_RETURN_TYPE_UINT: b.sample_type=5; break;
            default: status=3; break;
            }
            break;
        case D3D_SIT_STRUCTURED:
            b.kind=2; b.stride=resource.NumSamples;
            if (!b.stride || b.stride>2048 || b.stride%4) status=3;
            break;
        case D3D_SIT_BYTEADDRESS: b.kind=2; break;
        case D3D_SIT_SAMPLER:
            b.kind=4; b.sampler_type=(resource.uFlags & D3D_SIF_COMPARISON_SAMPLER)?3:1; break;
        default: status=3; break;
        }
        if (status) break;
    }
    reflection->Release(); return status;
}

extern "C" int zenit_d12_shader_warp_blob(ZenitD12Shader *shader, void **out) {
    if (!shader || !out) return 1;
    HRESULT hr=zenit_warp::blob(shader->code, (ID3DBlob **)out);
    if (FAILED(hr)) fprintf(stderr,"WARP shader lowering failed: 0x%08lx\n",(unsigned long)hr);

    return FAILED(hr) ? 2 : 0;
}

#ifdef ZENIT_D12_TEST
extern "C" int zenit_d12_test_warp_shader_parser() {
    // Literal payloads that look like resource tokens must remain opaque.
    zenit_warp::Words literal={0x00004002,0x00207000,0,5,0};
    size_t at=0; zenit_warp::Operand result;
    if (!zenit_warp::operand(literal,at,literal.size(),result) || at!=5 || result.type!=4) return 1;
    // Relative descriptor indices must not become static aliases.
    zenit_warp::Words relative={0x06207000,0,4,0x00100001,0};
    at=0;
    if (!zenit_warp::operand(relative,at,relative.size(),result) || at!=5 || result.immediate[1]!=SIZE_MAX) return 2;
    for (size_t length=0;length<relative.size();++length) {
        at=0;
        if (zenit_warp::operand(relative,at,length,result)) return 3;
    }
    zenit_warp::Words invalid_custom={53,1};
    size_t end,payload;
    if (zenit_warp::instruction(invalid_custom,0,end,payload)) return 4;
    ID3DBlob *invalid=nullptr,*rewritten=nullptr;
    if (FAILED(D3DCreateBlob(32,&invalid))) return 5;
    memset(invalid->GetBufferPointer(),0,32);
    auto words=(uint32_t *)invalid->GetBufferPointer();
    words[0]=0x43425844; words[6]=32; words[7]=UINT32_MAX;
    HRESULT hr=zenit_warp::blob(invalid,&rewritten);
    invalid->Release();
    if (rewritten) rewritten->Release();
    return FAILED(hr) && !rewritten ? 0 : 6;
}
#endif
