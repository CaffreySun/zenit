# Persistent interactive worker for an authenticated Windows acceptance queue.
# The host owns binaries, jobs and evidence. This worker only executes them.
$ErrorActionPreference = 'Stop'
$config = Get-Content (Join-Path $PSScriptRoot 'agent.json') -Raw | ConvertFrom-Json
$base = [string]$config.base
$headers = @{ Authorization = "Bearer $($config.token)" }
$work = [string]$config.work_dir
$generation = [string]$config.generation
. (Join-Path $PSScriptRoot 'native_input.ps1')
. (Join-Path $PSScriptRoot 'uia_query.ps1')
# Compile the native helper before reporting a worker heartbeat. A broken
# Add-Type must fail installation instead of consuming an E2E readiness timeout.
Initialize-WindowsNativeInput
New-Item -ItemType Directory -Force -Path $work | Out-Null
$PID | Set-Content (Join-Path $PSScriptRoot 'agent.pid')

# A tunnelled host (remote real-hardware sessions) answers gateway errors —
# 502/503/504, and Cloudflare's 520-530 while its edge reconnects to the origin —
# or drops the connection. Retry those for about 90 s instead of aborting the
# job and its app; any other HTTP status is a real error.
function Invoke-Retrying([scriptblock]$call) {
  $deadline = [DateTime]::UtcNow.AddSeconds(90)
  for ($attempt = 1; ; $attempt++) {
    try { return & $call }
    catch {
      $status = 0
      if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
      $transient = ($status -in 502, 503, 504) -or ($status -ge 520 -and $status -le 530) -or
        ($status -eq 0 -and $_.Exception -is [System.Net.WebException])
      if (-not $transient -or [DateTime]::UtcNow -ge $deadline) { throw }
      ('transient HTTP failure '+$status+' (attempt '+$attempt+'): '+$_.Exception.Message) | Write-Warning
      Start-Sleep -Milliseconds ([Math]::Min(1000 * $attempt, 10000))
    }
  }
}
function Api-Get([string]$path) {
  # Idle job polls return within 20 seconds. Bound a broken WAN connection so
  # the outer loop reconnects instead of appearing healthy for up to an hour.
  $timeout = if ($path.StartsWith('/next/')) { 35 } else { 3600 }
  return Invoke-Retrying { Invoke-RestMethod -Uri ($base+$path) -Headers $headers -TimeoutSec $timeout }
}
function Api-Post([string]$path, [object]$body) {
  $json = $body | ConvertTo-Json -Depth 100 -Compress
  return Invoke-Retrying { Invoke-RestMethod -Uri ($base+$path) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 35 }
}
function Api-Post-Raw([string]$path, [string]$json) {
  return Invoke-Retrying { Invoke-WebRequest -UseBasicParsing -Uri ($base+$path) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 35 }
}
function Download([string]$path, [string]$destination) {
  # A tunnelled response can arrive truncated or corrupted with status 200; an
  # executable damaged that way fails as "not a valid application". Verify the
  # host's SHA-256 before writing, and fetch again on mismatch.
  for ($attempt = 1; ; $attempt++) {
    # The cached suite runtime is ~110 MB: over a tunnel at ~1 MB/s a 120 s
    # limit would abort and restart the whole transfer every time.
    $response = Invoke-Retrying { Invoke-WebRequest -UseBasicParsing -Uri ($base+$path) -Headers $headers -TimeoutSec 1800 }
    $bytes = $response.RawContentStream.ToArray()
    $expected = [string]$response.Headers['X-Content-SHA256']
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $actual = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    $sha.Dispose()
    # Every artifact response carries the digest; a missing header means the
    # response was not the host's (or was stripped), so treat it as corrupt.
    if ($expected -and $actual -eq $expected) {
      [System.IO.File]::WriteAllBytes($destination, $bytes)
      return
    }
    ('download digest mismatch or missing for '+$path+' (attempt '+$attempt+', '+$bytes.Length+' bytes)') | Write-Warning
    if ($attempt -ge 4) { throw ('Download corrupted after retries: '+$path) }
  }
}
function Upload([string]$jobId, [string]$filename, [string]$directory) {
  $path = Join-Path $directory $filename
  if (-not (Test-Path $path)) { return }
  $timeout = if ($filename -in @('windows-presented-frames.zip', 'windows-suite-session.zip')) { 120 } else { 30 }
  Invoke-Retrying { Invoke-WebRequest -UseBasicParsing -Uri ($base+'/upload/'+$jobId+'/'+$filename) -Method Put -Headers $headers -ContentType 'application/octet-stream' -InFile $path -TimeoutSec $timeout } | Out-Null
}

function Wait-RpcResult([string]$path, [object]$proc) {
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-Path $path) {
      # The shared harness may still hold the newly created response open.
      # Read and validate the complete JSON before retiring the response.
      try {
        $text = Get-Content $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ($text.Length -gt 0) {
          $parsed = $text | ConvertFrom-Json -ErrorAction Stop
          if ($null -ne $parsed) {
            Remove-Item $path -Force -ErrorAction Stop
            return $text
          }
        }
      } catch { }
    }
    $proc.Refresh()
    if ($proc.HasExited) { throw 'E2E app exited while waiting for RPC response' }
    Start-Sleep -Milliseconds 10
  }
  throw 'Windows file RPC response timed out'
}
function Write-RpcRequest([string]$path, [string]$text) {
  $pending = $path + '.pending'
  [System.IO.File]::WriteAllText($pending, $text, (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::Move($pending, $path)
}

# A suite run on this machine (job.local_suite) talks file RPC to this worker
# in $script:suiteRpcDir instead of the host's /rpc queue: every harness
# request stays local, and screenshots go straight to the suite's paths.
$script:suiteRpcDir = $null
$script:suiteDeadline = [DateTime]::MaxValue
$script:suiteJobDir = $null
function Complete-Rpc([string]$jobId, [string]$requestId, [string]$text) {
  if ($script:suiteRpcDir) {
    Write-RpcRequest (Join-Path $script:suiteRpcDir ('res-'+$requestId+'.json')) $text
    return
  }
  Api-Post-Raw ('/rpc/complete/'+$jobId+'/'+$requestId) $text | Out-Null
}
function Deliver-Screenshot([string]$jobId, [string]$requestId, [string]$png, [string]$requestedPath) {
  if ($script:suiteRpcDir) {
    $parent = Split-Path -Parent $requestedPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Move-Item -Force -LiteralPath $png -Destination $requestedPath
    return
  }
  Invoke-Retrying { Invoke-WebRequest -UseBasicParsing -Uri ($base+'/rpc/screenshot/'+$jobId+'/'+$requestId) -Method Put -Headers $headers -ContentType 'image/png' -InFile $png -TimeoutSec 35 } | Out-Null
  Remove-Item $png -Force
}
# Next request of the local suite, oldest first; 'stop' once it has exited
# with nothing pending; $null after a short idle slice (the caller re-checks
# the app process between slices).
function Next-SuiteRpc([System.Diagnostics.Process]$suite) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds(200)
  while ($true) {
    $next = Get-ChildItem -LiteralPath $script:suiteRpcDir -Filter 'req-*.json' -File | Sort-Object LastWriteTimeUtc | Select-Object -First 1
    if ($next) {
      $id = $next.Name.Substring(4, $next.Name.Length - 9)
      # The suite publishes a request by renaming a complete .tmp, but a
      # real-time scanner (Defender on the real machine) or the rename itself
      # can still hold the file for a few ms: a sharing violation here is
      # transient, not a lost request (it aborted a 169-test run at test 101).
      $text = $null; $lastError = $null
      for ($read = 0; $read -lt 200; $read++) {
        try { $text = [System.IO.File]::ReadAllText($next.FullName); break } catch [System.IO.IOException] { $lastError = $_; Start-Sleep -Milliseconds 5 }
      }
      if ($null -eq $text) { throw "suite request $id stayed locked for 1s: $($lastError.Exception.Message)" }
      # The same scanner window covers the delete.
      for ($del = 0; $del -lt 200; $del++) {
        try { [System.IO.File]::Delete($next.FullName); break } catch [System.IO.IOException] { $lastError = $_; Start-Sleep -Milliseconds 5 }
        if ($del -eq 199) { throw "suite request $id could not be removed for 1s: $($lastError.Exception.Message)" }
      }
      if ($id -notmatch '^[0-9A-Za-z-]{1,64}$') { continue }
      $request = $text | ConvertFrom-Json
      return [pscustomobject]@{kind='rpc'; id=$id; method=[string]$request.method; path=[string]$request.path; body_json=[string]$request.body_json}
    }
    $suite.Refresh()
    if ($suite.HasExited) { return [pscustomobject]@{kind='stop'} }
    # The suite's own timeout cannot fire if its event loop is stuck; never
    # let a hung suite hold this worker (and its app) forever.
    if ([DateTime]::UtcNow -gt $script:suiteDeadline) {
      'local suite exceeded its deadline; terminating' | Add-Content (Join-Path $script:suiteJobDir 'agent-trace.log')
      Stop-Process -Id $suite.Id -Force -ErrorAction SilentlyContinue
      $suite.WaitForExit()
      return [pscustomobject]@{kind='stop'}
    }
    if ([DateTime]::UtcNow -ge $deadline) { return $null }
    Start-Sleep -Milliseconds 2
  }
}

# A batch job ships every executable, suite and the stage manifest in one
# archive. Its stages run here one after another as ordinary e2e/probe jobs
# (same code path), take their artifacts from the extracted archive instead of
# the network, keep their evidence locally, and the whole result set goes back
# in one upload at the end: no per-stage transfer or round trip over the tunnel.
$script:batchQueue = New-Object System.Collections.Queue
function Get-JobArtifact([object]$job, [string]$name, [string]$destination) {
  if ($job.batch) {
    $source = Join-Path ([string]$job.batch.bundle) ([string]$job.batch.files.$name)
    if (-not (Test-Path -LiteralPath $source)) { throw ('Batch artifact missing: '+$name) }
    Copy-Item -Force -LiteralPath $source -Destination $destination
    return
  }
  Download ('/artifacts/'+[string]$job.id+'/'+$name) $destination
}
function Ensure-SuiteRuntime([string]$jobId, [string]$runtimeSha) {
  if ($runtimeSha -notmatch '^[0-9a-f]{64}$') { throw 'Invalid suite runtime digest' }
  $cacheDir = Join-Path $PSScriptRoot '..\runtime-cache'
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  $runtime = Join-Path $cacheDir ('bun-'+$runtimeSha+'.exe')
  if (-not (Test-Path $runtime) -or (Get-FileHash -Algorithm SHA256 -LiteralPath $runtime).Hash.ToLower() -ne $runtimeSha) {
    Download ('/artifacts/'+$jobId+'/zenit-bun.exe') ($runtime+'.download')
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath ($runtime+'.download')).Hash.ToLower() -ne $runtimeSha) { throw 'Suite runtime digest mismatch' }
    Move-Item -Force -LiteralPath ($runtime+'.download') -Destination $runtime
  }
  return $runtime
}

while ($true) {
  if ($script:batchQueue.Count -gt 0) {
    $job = $script:batchQueue.Dequeue()
  } else {
    try {
      $job = Api-Get ('/next/'+$generation)
    } catch {
      Start-Sleep -Seconds 1
      continue
    }
  }
  if ($job.kind -eq 'retired') { break }
  if ($job.kind -eq 'idle') { continue }
  if ($job.kind -eq 'batch') {
    $batchId = [string]$job.id
    if ($batchId -notmatch '^[a-f0-9]{32}$') { continue }
    $batchDir = Join-Path $work $batchId
    $bundleDir = Join-Path $batchDir 'bundle'
    $resultsDir = Join-Path $batchDir 'results'
    try {
      New-Item -ItemType Directory -Force -Path $bundleDir, $resultsDir | Out-Null
      $zip = Join-Path $batchDir 'zenit-batch.zip'
      Download ('/artifacts/'+$batchId+'/zenit-batch.zip') $zip
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $bundleDir)
      Remove-Item -Force -LiteralPath $zip
      Ensure-SuiteRuntime $batchId ([string]$job.local_suite.runtime_sha256) | Out-Null
      $manifest = Get-Content -LiteralPath (Join-Path $bundleDir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($stage in $manifest.stages) {
        if ([string]$stage.name -notmatch '^[a-z0-9-]{1,48}$') { throw 'Invalid batch stage name' }
        $files = @{}
        $files[[string]$stage.exe_name] = [string]$stage.exe_name
        $stageSuite = $null
        if ($stage.suite) {
          $files['zenit-e2e-suite.js'] = [string]$stage.suite
          $stageSuite = [pscustomobject]@{runtime_sha256=[string]$job.local_suite.runtime_sha256; env=$stage.env}
        }
        $script:batchQueue.Enqueue([pscustomobject]@{
          kind=[string]$stage.kind; id=[guid]::NewGuid().ToString('N'); exe_name=[string]$stage.exe_name
          custom_titlebar=[bool]$stage.custom_titlebar; capture_frames=[bool]$stage.capture_frames
          trace_frames=[bool]$stage.trace_frames; capture_desktop=$false; allow_foreground=$false
          local_suite=$stageSuite
          batch=[pscustomobject]@{parent=$batchId; stage=[string]$stage.name; bundle=$bundleDir; results=$resultsDir; files=[pscustomobject]$files}
        })
      }
      $script:batchQueue.Enqueue([pscustomobject]@{kind='batch-finish'; id=$batchId; results=$resultsDir; dir=$batchDir})
      Write-Host ('Batch '+$batchId+': '+@($manifest.stages).Count+' stages')
    } catch {
      $errorText = ($_ | Out-String)
      try { Api-Post ('/complete/'+$batchId) @{ exit_code=1; error=('Batch setup failed: '+$errorText) } | Out-Null } catch { }
    }
    continue
  }
  if ($job.kind -eq 'batch-finish') {
    $batchId = [string]$job.id
    $exitCode = 0
    $errorText = ''
    foreach ($result in Get-ChildItem -LiteralPath $job.results -Filter 'stage-result.json' -Recurse -File) {
      $value = Get-Content -LiteralPath $result.FullName -Raw | ConvertFrom-Json
      if ($value.exit_code -ne 0) { $exitCode = 1; $errorText += $value.stage + ' exit ' + $value.exit_code + '. ' }
    }
    # One archive per stage: a tunnel caps a single request body near 100 MB.
    $uploaded = @()
    try {
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      foreach ($stageDir in Get-ChildItem -LiteralPath $job.results -Directory) {
        $name = 'batch-'+$stageDir.Name+'.zip'
        $archive = Join-Path $job.dir $name
        if (Test-Path $archive) { Remove-Item -Force $archive }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($stageDir.FullName, $archive, [System.IO.Compression.CompressionLevel]::Fastest, $false)
        Invoke-Retrying { Invoke-WebRequest -UseBasicParsing -Uri ($base+'/upload/'+$batchId+'/'+$name) -Method Put -Headers $headers -ContentType 'application/octet-stream' -InFile $archive -TimeoutSec 1800 } | Out-Null
        $uploaded += $name
      }
      $completion = Api-Post ('/complete/'+$batchId) @{ exit_code=$exitCode; error=$errorText; uploaded=$uploaded }
      if ($completion.status -in @('passed','failed')) { Remove-Item -Recurse -Force -LiteralPath $job.dir }
    } catch {
      # Keep the results on disk if the host went away during the upload.
      ('Batch upload failed: '+($_ | Out-String)) | Write-Warning
      try { Api-Post ('/complete/'+$batchId) @{ exit_code=1; error=('Batch upload failed: '+($_ | Out-String)); uploaded=$uploaded } | Out-Null } catch { }
    }
    Write-Host ('Batch '+$batchId+' finished: exit '+$exitCode)
    continue
  }
  if ($job.kind -ne 'acceptance' -and $job.kind -ne 'e2e' -and $job.kind -ne 'probe') { continue }

  $jobId = [string]$job.id
  if ($jobId -notmatch '^[a-f0-9]{32}$') { continue }
  $dir = Join-Path $work $jobId
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $exitCode = 1
  $errorText = ''
  try {
    if ($job.kind -eq 'probe') {
      $exeName = [string]$job.exe_name
      if ($exeName -notin @('zenit-windows-font-smoke.exe', 'zenit-windows-drop-contract.exe', 'zenit-windows-gpu-resources-contract.exe')) { throw 'Unknown native probe' }
      $exe = Join-Path $dir $exeName
      Get-JobArtifact $job $exeName $exe
      $proc = New-Object System.Diagnostics.Process
      $proc.StartInfo.FileName = $exe
      $proc.StartInfo.WorkingDirectory = $dir
      $proc.StartInfo.UseShellExecute = $false
      $proc.StartInfo.CreateNoWindow = $true
      $proc.StartInfo.RedirectStandardOutput = $true
      $proc.StartInfo.RedirectStandardError = $true
      $proc.StartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
      $proc.StartInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
      $started = $false
      try {
        if (-not $proc.Start()) { throw 'Native probe did not start' }
        $started = $true
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(120000)) { throw 'Native probe timed out' }
        $exitCode = $proc.ExitCode
      } finally {
        if ($started) {
          if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit() }
          # Preserve the completed portion even when the process deadline fires.
          [System.IO.File]::WriteAllText((Join-Path $dir 'windows-probe-stdout.log'), $stdout.GetAwaiter().GetResult(), (New-Object System.Text.UTF8Encoding($false)))
          [System.IO.File]::WriteAllText((Join-Path $dir 'windows-probe-stderr.log'), $stderr.GetAwaiter().GetResult(), (New-Object System.Text.UTF8Encoding($false)))
        }
        $proc.Dispose()
      }
    } elseif ($job.kind -eq 'e2e') {
      $exeName = [string]$job.exe_name
      if ($exeName -notin @('zenit-windows-text-input.exe', 'zenit-windows-storybook.exe', 'zenit-windows-render-gallery.exe')) { throw 'Unknown E2E executable' }
      $exe = Join-Path $dir $exeName
      $rpcDir = Join-Path $dir 'rpc'
      New-Item -ItemType Directory -Force -Path $rpcDir | Out-Null
      Get-JobArtifact $job $exeName $exe
      $script:suiteRpcDir = $null
      $suiteProc = $null
      if ($job.local_suite) {
        # The bun runtime is the same across runs: keep it by digest.
        $suiteRuntime = Ensure-SuiteRuntime $jobId ([string]$job.local_suite.runtime_sha256)
        $suiteScript = Join-Path $dir 'zenit-e2e-suite.js'
        Get-JobArtifact $job 'zenit-e2e-suite.js' $suiteScript
      }
      $heldKeys = New-Object 'System.Collections.Generic.HashSet[int]'
      $originalForeground = [IntPtr]::Zero
      Initialize-WindowsNativeInput
      $foregroundBeforeLaunch = [ZenitNativeInput]::GetForegroundWindow()
      if ($job.allow_foreground) { $originalForeground = $foregroundBeforeLaunch }
      $env:ZENIT_E2E_BACKGROUND = if ($job.allow_foreground) { '0' } else { '1' }
      if ($job.allow_foreground) { $env:ZENIT_WINDOWS_INPUT_TRACE = '1' }
      $env:ZENIT_E2E_FILE_RPC_DIR = $rpcDir
      if ($job.capture_desktop -and $job.allow_foreground) { $env:ZENIT_WINDOWS_DESKTOP_WAKE_INPUT = '1' }
      if ($job.capture_desktop) { $env:ZENIT_WINDOWS_DESKTOP_CAPTURE = '1' }
      if ($job.trace_frames) { $env:ZENIT_WINDOWS_FRAME_TIMING = '1' }
      $frameDir = Join-Path $dir 'presented-frames'
      if ($job.capture_frames) {
        New-Item -ItemType Directory -Force -Path $frameDir | Out-Null
        $env:ZENIT_WINDOWS_FRAME_CAPTURE_DIR = $frameDir
      }
      # Console-subsystem examples otherwise spawn conhost and steal foreground
      # even when their Win32 UI uses SW_SHOWNOACTIVATE.
      $proc = New-Object System.Diagnostics.Process
      $proc.StartInfo.FileName = $exe
      if ($job.custom_titlebar) { $proc.StartInfo.Arguments = '--zenit-custom-titlebar' }
      $proc.StartInfo.UseShellExecute = $false
      $proc.StartInfo.CreateNoWindow = $true
      $proc.StartInfo.RedirectStandardOutput = $true
      $proc.StartInfo.RedirectStandardError = $true
      $proc.StartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
      $proc.StartInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
      if (-not $proc.Start()) { throw 'E2E app did not start' }
      $appStdout = $proc.StandardOutput.ReadToEndAsync()
      $appStderr = $proc.StandardError.ReadToEndAsync()
      try {
      $proc.Id | Set-Content (Join-Path $PSScriptRoot 'active-app.pid')
      Remove-Item Env:ZENIT_E2E_BACKGROUND
      Remove-Item Env:ZENIT_WINDOWS_INPUT_TRACE -ErrorAction SilentlyContinue
      Remove-Item Env:ZENIT_E2E_FILE_RPC_DIR
      Remove-Item Env:ZENIT_WINDOWS_FRAME_CAPTURE_DIR -ErrorAction SilentlyContinue
      Remove-Item Env:ZENIT_WINDOWS_DESKTOP_WAKE_INPUT -ErrorAction SilentlyContinue
      Remove-Item Env:ZENIT_WINDOWS_DESKTOP_CAPTURE -ErrorAction SilentlyContinue
      Remove-Item Env:ZENIT_WINDOWS_FRAME_TIMING -ErrorAction SilentlyContinue
      for ($ready=0; $ready -lt 100 -and -not (Test-Path (Join-Path $rpcDir 'owner.json')); $ready++) {
        $proc.Refresh()
        if ($proc.HasExited) { throw "E2E app exited before harness startup: $($proc.ExitCode)" }
        Start-Sleep -Milliseconds 100
      }
      if (-not (Test-Path (Join-Path $rpcDir 'owner.json'))) { throw 'E2E harness did not start' }
      $foregroundAfterLaunch=[ZenitNativeInput]::GetForegroundWindow()
      @{foreground_before=$foregroundBeforeLaunch.ToInt64(); foreground_after=$foregroundAfterLaunch.ToInt64(); allow_foreground=[bool]$job.allow_foreground} | ConvertTo-Json | Set-Content (Join-Path $dir 'native-startup.json')
      'harness ready' | Add-Content (Join-Path $dir 'agent-trace.log')
      if ($job.local_suite) {
        $script:suiteRpcDir = Join-Path $dir 'suite-rpc'
        New-Item -ItemType Directory -Force -Path $script:suiteRpcDir | Out-Null
        $suiteProc = New-Object System.Diagnostics.Process
        $suiteProc.StartInfo.FileName = $suiteRuntime
        $suiteProc.StartInfo.Arguments = '"'+$suiteScript+'"'
        $suiteProc.StartInfo.WorkingDirectory = $dir
        $suiteProc.StartInfo.UseShellExecute = $false
        $suiteProc.StartInfo.CreateNoWindow = $true
        $suiteProc.StartInfo.RedirectStandardOutput = $true
        $suiteProc.StartInfo.RedirectStandardError = $true
        $suiteProc.StartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $suiteProc.StartInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $suiteProc.StartInfo.EnvironmentVariables['ZENIT_E2E_FILE_RPC_DIR'] = $script:suiteRpcDir
        $suiteProc.StartInfo.EnvironmentVariables['ZENIT_E2E_SESSION_ROOT'] = (Join-Path $dir 'session')
        foreach ($entry in $job.local_suite.env.PSObject.Properties) { $suiteProc.StartInfo.EnvironmentVariables[$entry.Name] = [string]$entry.Value }
        $suiteTimeoutMs = 900000
        if ($job.local_suite.env.ZENIT_E2E_SUITE_TIMEOUT_MS) { $suiteTimeoutMs = [double]$job.local_suite.env.ZENIT_E2E_SUITE_TIMEOUT_MS }
        $script:suiteDeadline = [DateTime]::UtcNow.AddMilliseconds($suiteTimeoutMs + 120000)
        $script:suiteJobDir = $dir
        if (-not $suiteProc.Start()) { throw 'E2E suite did not start' }
        $suiteStdout = $suiteProc.StandardOutput.ReadToEndAsync()
        $suiteStderr = $suiteProc.StandardError.ReadToEndAsync()
        'local suite started' | Add-Content (Join-Path $dir 'agent-trace.log')
      }
      $nativeCloseAccepted=$false
        while ($true) {
          $proc.Refresh()
          if ($proc.HasExited -and -not $nativeCloseAccepted) { throw "E2E app exited: $($proc.ExitCode)" }
          'poll' | Add-Content (Join-Path $dir 'agent-trace.log')
          $rpc = if ($suiteProc) { Next-SuiteRpc $suiteProc } else { Api-Get ('/rpc/next/'+$jobId) }
          ('received '+($rpc | ConvertTo-Json -Compress -Depth 5)) | Add-Content (Join-Path $dir 'agent-trace.log')
          if ($rpc.kind -eq 'stop') { $exitCode = if ($suiteProc) { $suiteProc.ExitCode } else { 0 }; break }
          if ($rpc.kind -ne 'rpc') { continue }
          $requestId = [string]$rpc.id
          if ($rpc.path -eq '/windows/native-input') {
            $nativeBody = $rpc.body_json | ConvertFrom-Json
            if ($nativeCloseAccepted -and $nativeBody.action -notin @('receiver-status','receiver-stop','drag-cancel')) { throw 'Only owned cleanup RPC is allowed after accepted close' }
            if (-not $job.allow_foreground -and $nativeBody.action -notin @('status','uia-tree','uia-invoke','uia-toggle','uia-set-value','uia-set-range','uia-select','uia-expand','uia-text-action')) {
              # A suite running beside the app gets the same refusal the host queue answers with
              # (HTTP 403), so background-safety probes can assert the denial instead of losing the job.
              if ($suiteProc) { Complete-Rpc $jobId $requestId (@{ok=$false; error='Native Windows input requires --allow-foreground'} | ConvertTo-Json -Compress); continue }
              throw 'Native input needs --allow-foreground'
            }
            try { $nativeResult = Invoke-WindowsNativeInput $proc $nativeBody $heldKeys }
            catch { $nativeResult = @{ok=$false; error=$_.Exception.Message} }
            if ($nativeBody.action -eq 'close' -and $nativeResult.ok -and $nativeResult.exited -and $nativeResult.exit_code -eq 0) { $nativeCloseAccepted=$true }
            if ($nativeBody.action -eq 'status') {
              $nativeResult.foreground_before_launch=$foregroundBeforeLaunch.ToInt64()
              $nativeResult.foreground_after_launch=$foregroundAfterLaunch.ToInt64()
            }
            Complete-Rpc $jobId $requestId ($nativeResult | ConvertTo-Json -Compress -Depth 12)
            continue
          }
          if ($nativeCloseAccepted) { throw 'App RPC is unavailable after accepted close' }
          if ($rpc.path -eq '/windows/native-desktop') {
            if (-not $job.allow_foreground) {
              if ($suiteProc) { Complete-Rpc $jobId $requestId (@{ok=$false; error='Native Windows input requires --allow-foreground'} | ConvertTo-Json -Compress); continue }
              throw 'Native desktop capture needs --allow-foreground'
            }
            $nativeStatus = Get-WindowsNativeStatus $proc
            if (-not $nativeStatus.foreground_owned) { throw 'Desktop capture refused: foreground is not owned by test process' }
            $captureWindow=[IntPtr]::new([long]$nativeStatus.foreground_hwnd)
            Add-Type -AssemblyName System.Drawing
            $oldDpi=[ZenitNativeInput]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
            if ($oldDpi -eq [IntPtr]::Zero) { throw 'Native capture DPI context unavailable' }
            try {
            if ([ZenitNativeInput]::DwmFlush() -ne 0) { throw 'Native desktop synchronization failed' }
            $rect = New-Object ZenitNativeInput+Rect
            $origin = New-Object ZenitNativeInput+Point
            if (-not [ZenitNativeInput]::ClientToScreen($captureWindow,[ref]$origin)) { throw 'Client origin unavailable' }
            if (-not [ZenitNativeInput]::GetWindowRect($captureWindow,[ref]$rect)) { throw 'Owned window rectangle unavailable' }
            $png = Join-Path $dir ('native-'+$requestId+'.png')
            $bmp = New-Object System.Drawing.Bitmap(($rect.Right-$rect.Left),($rect.Bottom-$rect.Top))
            try {
              $g = [System.Drawing.Graphics]::FromImage($bmp)
              try { $g.CopyFromScreen($rect.Left,$rect.Top,0,0,$bmp.Size) } finally { $g.Dispose() }
              $bmp.Save($png,[System.Drawing.Imaging.ImageFormat]::Png)
            } finally { $bmp.Dispose() }
            } finally { [ZenitNativeInput]::SetThreadDpiAwarenessContext($oldDpi) | Out-Null }
            Deliver-Screenshot $jobId $requestId $png ([string](($rpc.body_json | ConvertFrom-Json).path))
            $requestedPath = [string](($rpc.body_json | ConvertFrom-Json).path)
            Complete-Rpc $jobId $requestId (@{ok=$true;path=$requestedPath;client_x=$origin.X-$rect.Left;client_y=$origin.Y-$rect.Top} | ConvertTo-Json -Compress)
            continue
          }
          if ($rpc.path -in @('/screenshot','/frames/capture')) {
            $bmpPath = Join-Path $dir ('screen-'+$requestId+'.bmp')
            $png = Join-Path $dir ('screen-'+$requestId+'.png')
            $reqPath = Join-Path $rpcDir ('req-'+$requestId+'.json')
            $resPath = Join-Path $rpcDir ('res-'+$requestId+'.json')
            $captureBody = $rpc.body_json | ConvertFrom-Json
            $captureBody.path = $bmpPath
            $body = $captureBody | ConvertTo-Json -Compress
            $requestText = @{method='POST';path=$rpc.path;body_json=$body} | ConvertTo-Json -Compress
            Write-RpcRequest $reqPath $requestText
            $capture = (Wait-RpcResult $resPath $proc) | ConvertFrom-Json
            if ($rpc.path -eq '/frames/capture' -and -not $capture.ok) {
              # Rejected/timed-out requests are RPC errors, not App failures.
              Complete-Rpc $jobId $requestId ($capture | ConvertTo-Json -Compress)
              continue
            }
            if (-not $capture.ok -or -not (Test-Path $bmpPath)) { throw 'Render target capture failed' }
            Add-Type -AssemblyName System.Drawing
            $bmp = [System.Drawing.Bitmap]::FromFile($bmpPath)
            try { $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png) }
            finally { $bmp.Dispose() }
            Deliver-Screenshot $jobId $requestId $png ([string](($rpc.body_json | ConvertFrom-Json).path))
            Remove-Item $bmpPath -Force
            $requestedPath = [string](($rpc.body_json | ConvertFrom-Json).path)
            $captureResult = @{ok=$true;path=$requestedPath}
            if ($rpc.path -eq '/frames/capture') {
              foreach ($field in @('sample_ms','requested_ms','frame_index','x','effective_opacity')) { $captureResult[$field] = $capture.$field }
            }
            $resultText = $captureResult | ConvertTo-Json -Compress
            Complete-Rpc $jobId $requestId $resultText
            continue
          }
          $reqPath = Join-Path $rpcDir ('req-'+$requestId+'.json')
          $resPath = Join-Path $rpcDir ('res-'+$requestId+'.json')
          $requestText = @{method=$rpc.method;path=$rpc.path;body_json=$rpc.body_json} | ConvertTo-Json -Depth 100 -Compress
          Write-RpcRequest $reqPath $requestText
          ('wrote '+$requestId) | Add-Content (Join-Path $dir 'agent-trace.log')
          $resultText = Wait-RpcResult $resPath $proc
          ('read '+$requestId+' bytes='+$resultText.Length) | Add-Content (Join-Path $dir 'agent-trace.log')
          ('posting '+$requestId) | Add-Content (Join-Path $dir 'agent-trace.log')
          Complete-Rpc $jobId $requestId $resultText
          ('completed '+$requestId) | Add-Content (Join-Path $dir 'agent-trace.log')
        }
        # A local suite has no host to close the frame archive: serialize with
        # the app's frame writers and stop further archive writes before the
        # app is terminated (the host sends this RPC for a host-driven suite).
        if ($suiteProc -and $job.capture_frames -and -not $proc.HasExited) {
          $finishId = [guid]::NewGuid().ToString()
          Write-RpcRequest (Join-Path $rpcDir ('req-'+$finishId+'.json')) (@{method='POST';path='/frames/capture/finish';body_json='{}'} | ConvertTo-Json -Compress)
          $finished = Wait-RpcResult (Join-Path $rpcDir ('res-'+$finishId+'.json')) $proc
          [System.IO.File]::WriteAllText((Join-Path $dir 'frame-capture-finish.json'), $finished, (New-Object System.Text.UTF8Encoding($false)))
          $finishedValue = $finished | ConvertFrom-Json
          if (-not $finishedValue.ok -or -not $finishedValue.finished) { $exitCode = 1; 'frame capture finish failed' | Add-Content (Join-Path $dir 'agent-trace.log') }
        }
      } finally {
        if ('ZenitNativeInput' -as [type]) { try { [ZenitNativeInput]::DragCancel() } catch { 'owned drag cleanup failed' | Add-Content (Join-Path $dir 'agent-trace.log') } }
        if ('ZenitNativeInput' -as [type]) { try { [ZenitNativeInput]::ReceiverStop() } catch { 'owned receiver cleanup failed' | Add-Content (Join-Path $dir 'agent-trace.log') } }
        foreach ($vk in $heldKeys) { [ZenitNativeInput]::Key($vk,$true) | Out-Null }
        $restoreForeground = -not $proc.HasExited -and [ZenitNativeInput]::Owned([ZenitNativeInput]::GetForegroundWindow(),$proc.Id)
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id }
        $proc.WaitForExit()
        [System.IO.File]::WriteAllText((Join-Path $dir 'windows-e2e-stdout.log'),$appStdout.GetAwaiter().GetResult(),(New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $dir 'windows-e2e-stderr.log'),$appStderr.GetAwaiter().GetResult(),(New-Object System.Text.UTF8Encoding($false)))
        if ($restoreForeground -and $originalForeground -ne [IntPtr]::Zero -and [ZenitNativeInput]::IsWindow($originalForeground)) {
          [ZenitNativeInput]::SetForegroundWindow($originalForeground) | Out-Null
        }
        Remove-Item (Join-Path $PSScriptRoot 'active-app.pid') -Force -ErrorAction SilentlyContinue
        if ($suiteProc) {
          if (-not $suiteProc.HasExited) { Stop-Process -Id $suiteProc.Id -Force -ErrorAction SilentlyContinue }
          $suiteProc.WaitForExit()
          $suiteLog = $suiteStdout.GetAwaiter().GetResult() + $suiteStderr.GetAwaiter().GetResult()
          [System.IO.File]::WriteAllText((Join-Path $dir 'windows-suite.log'),$suiteLog,(New-Object System.Text.UTF8Encoding($false)))
          $sessionDir = Join-Path $dir 'session'
          if (Test-Path $sessionDir) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::CreateFromDirectory($sessionDir, (Join-Path $dir 'windows-suite-session.zip'), [System.IO.Compression.CompressionLevel]::Fastest, $false)
          }
          $script:suiteRpcDir = $null
        }
      }
    } else {
      Download ('/artifacts/'+$jobId+'/Zenit-UI-Scroll.exe') (Join-Path $dir 'Zenit-UI-Scroll.exe')
      Download ('/artifacts/'+$jobId+'/windows_ui_acceptance.ps1') (Join-Path $dir 'windows_ui_acceptance.ps1')
      $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $dir 'windows_ui_acceptance.ps1'),
        '-ExePath', (Join-Path $dir 'Zenit-UI-Scroll.exe'), '-OutputDir', $dir
      ) -PassThru -Wait
      $exitCode = $proc.ExitCode
    }
  } catch {
    $errorText = ($_ | Out-String)
    $errorText | Set-Content (Join-Path $dir 'agent.log')
  }
  if (Test-Path (Join-Path $dir 'presented-frames')) {
    try {
      # Stream entries to disk; large frame sets must not accumulate in memory.
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $archive = Join-Path $dir 'windows-presented-frames.zip'
      if (Test-Path $archive) { Remove-Item $archive -Force }
      [System.IO.Compression.ZipFile]::CreateFromDirectory(
        (Join-Path $dir 'presented-frames'), $archive,
        [System.IO.Compression.CompressionLevel]::Fastest, $false)
    } catch {
      $exitCode = 1
      $errorText += "Frame archive failed: " + ($_ | Out-String)
      $errorText | Set-Content (Join-Path $dir 'agent.log')
    }
  }
  if ($job.batch) {
    # Batch stage: evidence stays here (uploaded once with the batch); the stage
    # directory moves under the batch results by stage name.
    @{stage=[string]$job.batch.stage; exit_code=$exitCode; error=$errorText} | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $dir 'stage-result.json')
    foreach ($leftover in @('zenit-e2e-suite.js', [string]$job.exe_name, 'rpc', 'suite-rpc', 'presented-frames', 'session')) {
      $path = Join-Path $dir $leftover
      if (Test-Path -LiteralPath $path) { Remove-Item -Recurse -Force -LiteralPath $path -ErrorAction SilentlyContinue }
    }
    Move-Item -Force -LiteralPath $dir -Destination (Join-Path ([string]$job.batch.results) ([string]$job.batch.stage))
    Write-Host ('  stage '+$job.batch.stage+': exit '+$exitCode)
    continue
  }
  $uploadFailed = $false
  foreach ($filename in @(
    'windows-presented-frames.zip',
    'zenit-accept.log', 'zenit-app-stderr.log', 'zenit-app-stdout.log',
    'zenit-empty.png', 'zenit-long.png', 'zenit-selected.png',
    'zenit-home.png', 'zenit-end.png', 'agent.log',
    'windows-e2e-stdout.log', 'windows-e2e-stderr.log', 'agent-trace.log',
    'windows-probe-stdout.log', 'windows-probe-stderr.log', 'native-startup.json',
    'windows-suite.log', 'windows-suite-session.zip'
  )) {
    $uploaded = $false
    for ($attempt=0; $attempt -lt 3; $attempt++) {
      try { Upload $jobId $filename $dir; $uploaded = $true; break }
      catch { Start-Sleep -Milliseconds 300 }
    }
    if (-not $uploaded) {
      $uploadFailed = $true
      $errorText += "Artifact upload failed: $filename. "
    }
  }
  if ($uploadFailed) { $exitCode = 1 }
  try {
    $completion = Api-Post ('/complete/'+$jobId) @{ exit_code=$exitCode; error=$errorText }
    # Retain failed evidence for recovery; completion alone is not acceptance.
    if (-not $uploadFailed -and $completion.status -eq 'passed') {
      Remove-Item -Recurse -Force $dir
    }
  } catch {
    # Preserve the guest job directory if the host disappears during upload.
    Start-Sleep -Seconds 1
  }
}
