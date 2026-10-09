import { clickTestId, query, resizeWindow, screenshot, sleep, tree, waitForServerReady } from "./client";
import { decodePng } from "./png";
import { assert, getSessionDir, run, test } from "./runner";
const encode=(x:number)=>Math.round(255*(x<=.0031308?12.92*x:1.055*Math.max(x,0)**(1/2.4)-.055));
const clamp=(x:number,lo=0,hi=1)=>Math.max(lo,Math.min(hi,x));
const mix=(a:number,b:number,t:number)=>a+(b-a)*t;
const ramp=(x:number)=>{const q=clamp(x,0,110)/11,i=Math.floor(q);return i%2?1-(q-i):q-i;};
const ids=["base","circle","squircle","concave","mixed","bottom","warp-zero","warp-three","refraction-zero","thick","magnify","radius","falloff","scale","edge","gap","light-right","light-left","spec-saturation","tint","gradient","rounded","intensity-two","blur"];
async function capture(stage:string){
  await sleep(150);
  const path=`${getSessionDir()}/windows-glass-${stage}.png`;
  assert((await screenshot(path)).ok,"optical capture failed");
  const png=decodePng(path),scale=png.width/(await tree()).rect.w;
  const nodes=new Map<string,any>();
  for(const id of ids){const n=(await query(`optical.${id}`))[0];assert(n,`missing ${id}`);nodes.set(id,n);}
  const pixel=(id:string,x:number,y:number)=>{
    const n=nodes.get(id),px=Math.floor((n.rect.x+x)*scale),py=Math.floor((n.rect.y+y)*scale);
    assert(px>=0&&py>=0&&px<png.width&&py<png.height,`${id} outside screenshot`);
    const i=(py*png.width+px)*png.channels;
    return [png.pixels[i],png.pixels[i+1],png.pixels[i+2]];
  };
  const region=(id:string)=>{const out:number[]=[];for(let y=3;y<77;y+=2)for(let x=3;x<77;x+=2)out.push(...pixel(id,x,y));return out;};
  const local=(id:string,x:number,y:number)=>{const n=nodes.get(id);return [(Math.floor((n.rect.x+x)*scale)+.5)/scale-n.rect.x,(Math.floor((n.rect.y+y)*scale)+.5)/scale-n.rect.y];};
  console.log(`  ${path}, scale=${scale}`);
  return {pixel,region,local,scale};
}
function near(actual:number[],expected:number[],label:string,tolerance=4){assert(actual.every((x,i)=>Math.abs(x-expected[i])<=tolerance),`${label}: ${actual}, expected ${expected}`);}

// CPU ray oracle for a circle top / flat bottom, no specular, no blur. Use
// Snell's angle law against a linear grayscale ramp; no screenshots/goldens
// participate in deriving the expected values.
function circleRay(x:number,y:number,s:number,warp=2,refraction=1){
  const half=40*s,p=[(x-40)*s,(y-40)*s],inset=half-Math.max(Math.abs(p[0]),Math.abs(p[1]));
  const topWidth=clamp(half*.18,2,half),bottomWidth=clamp(half*.12,2,half);
  const topT=clamp(inset/topWidth),bottomT=clamp(inset/bottomWidth);
  const profile=(t:number)=>{const q=1-clamp(t),h=Math.sqrt(Math.max(1-q*q,0));return [h,q/Math.max(h,1e-5)*1.08];};
  const edge=profile(topT),topEdge=(1-topT)**2.3,bottomEdge=(1-bottomT)**2.1;
  const thickness=12+Math.min(topWidth*(.52+.48*edge[0]),20)*(.38+topEdge*.62)+Math.min(bottomWidth*.38,20)*(.24+bottomEdge*.76);
  const bodyT=1-(1-clamp(inset/half))**mix(1.15,3.75,(1-.35)/1.25),body=profile(bodyT);
  const height=mix(edge[0],body[0],bodyT),slope=mix(edge[1],body[1],bodyT);
  const cover=clamp((.58-.1)/1.4),hardness=clamp((2.2-.4)/5.6);
  const envelope=(1-Math.exp(-bodyT*(.8+cover*4.2)))**mix(.78,2.4,hardness);
  const bezel=mix(topWidth,half,bodyT),physicalSlope=slope*thickness/bezel;
  const incident=Math.atan(physicalSlope),sinI=Math.sin(incident);
  const boost=mix(1,.15+.85*envelope,bodyT)*warp*refraction;
  const sdfNormal=[p[0]<0?-1:1,0],len=Math.hypot(...p),radial=p.map(v=>v/len);
  const t=clamp((bodyT-.10)/(.92-.10)),directionT=t*t*(3-2*t);
  const direction=[mix(sdfNormal[0],radial[0],directionT),mix(0,radial[1],directionT)],dl=Math.hypot(...direction);
  const colors=[1.430,1.450,1.478].map(ior=>{
    const refracted=Math.asin(sinI/ior),shift=height*thickness*(Math.tan(incident)-Math.tan(refracted))*boost;
    return ramp(15+x+direction[0]/dl*shift/s);
  });
  const luma=colors[0]*.2126+colors[1]*.7152+colors[2]*.0722,sat=1.02+(topEdge+bottomEdge*.45)*.18;
  return colors.map(c=>encode(clamp(mix(luma,c,sat))));
}

test("Windows optical glass executes Snell dispersion and every material control on live backdrop",async()=>{
  await waitForServerReady(15000);
  assert((await resizeWindow(1200,850)).ok,"optics resize failed");
  assert((await clickTestId("gallery.optics")).ok,"optics activation failed");
  const verify=async(stage:string)=>{
    const image=await capture(stage);
    // Keep analytic ray samples away from ramp cusps: rasterized gradients
    // average a pixel footprint there, unlike the continuous CPU ramp.
    for(const x of [3,6,12,22,32]){
      const [lx,ly]=image.local("circle",x,40);
      near(image.pixel("circle",x,40),circleRay(lx,ly,image.scale),`circle Snell x=${x}`);
      const [bx]=image.local("base",x,40);
      near(image.pixel("base",x,40),image.pixel("base",x,-10),`zero intensity backdrop identity x=${x}`);
      near(image.pixel("base",x,40),[0,0,0].map(()=>encode(ramp(15+bx))),`zero intensity straight ray x=${x}`);
      for(const [id,warp,refraction] of [["warp-zero",0,1],["warp-three",3,1],["refraction-zero",1,0]] as const){
        const [px,py]=image.local(id,x,40);
        near(image.pixel(id,x,40),circleRay(px,py,image.scale,warp,refraction),`${id} x=${x}`);
      }
    }
    // Include the old cusp position in a direct backdrop identity gate.
    for(const id of ["base","warp-zero","refraction-zero"])
      near(image.pixel(id,7,40),image.pixel(id,7,-10),`${id} preserves rasterized cusp`);
    const baseline=image.region("circle");
    const differences: [string,number][]=[];
    const changed=(id:string,reference=baseline)=>{
      const p=image.region(id),delta=p.reduce((n,v,i)=>n+Math.abs(v-reference[i]),0)/p.length;
      console.log(`  ${id} mean channel delta=${delta.toFixed(3)}`);
      differences.push([id,delta]);
    };
    for(const id of ids.filter(id=>!["base","circle","rounded","refraction-zero"].includes(id)))changed(id);
    const [cornerX]=image.local("rounded",0,0);
    near(image.pixel("rounded",0,0),[0,0,0].map(()=>encode(ramp(15+cornerX))),"rounded corner retains original ramp",5);
    near(image.pixel("rounded",0,0),image.pixel("rounded",0,-10),"rounded corner preserves rasterized backdrop");
    const leftLight=image.pixel("light-left",.5,40),rightLight=image.pixel("light-right",.5,40);
    assert(leftLight[0]>rightLight[0]+20,`light angle did not reverse the illuminated rim: ${leftLight} / ${rightLight}`);
    // Thick colored optics must absorb green more strongly than red, while
    // all channels remain finite and within the encoded target range.
    for(const [id,delta] of differences)assert(delta>.12,`${id} did not affect optical pixels: ${delta}`);
    const tint=image.pixel("tint",40,40);assert(tint[0]>tint[1]+30&&tint[2]>tint[1]+10,`colored curved transmission ${tint}`);
    return image;
  };
  await verify("parameters");
  assert((await resizeWindow(1150,800)).ok,"optics second resize failed");
  const before=await verify("parameters-resized");
  assert((await clickTestId("gallery.optics-change")).ok,"optical material mutation failed");
  const after=await capture("parameters-mutated");
  for(const id of ["spec-saturation","intensity-two","squircle","bottom","gradient"]){
    const a=before.region(id),b=after.region(id),delta=a.reduce((sum,v,i)=>sum+Math.abs(v-b[i]),0)/a.length;
    console.log(`  live ${id} delta=${delta.toFixed(3)}`);
    assert(delta>.5,`${id} live mutation did not change pixels: ${delta}`);
  }
  const unchanged=after.region("circle");
  assert(before.region("circle").every((v,i)=>v===unchanged[i]),"changing another slab contaminated the unchanged optical slab");
});
run();
