/*
Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/
// Metal translation of AMD FSR 1 EASU/RCAS, upstream a21ffb8f6c13233ba336352bdff293894c706575.

static float riosFsrRcp(float value) {
  return as_type<float>(0x7ef07ebbu-as_type<uint>(value));
}
static float3 riosFsrLoad(texture2d<float,access::read> input, int2 p) {
  return input.read(uint2(clamp(p,int2(0),int2(input.get_width(),input.get_height())-1))).rgb;
}
static float riosFsrLuma(float3 c) { return c.b*0.5+(c.r*0.5+c.g); }

static void riosFsrDirection(thread float2& direction, thread float& length, float weight,
                             float a, float b, float c, float d, float e) {
  const float2 difference = float2(d-b,e-a);
  direction += difference*weight;
  float2 strength = saturate(abs(difference)*float2(
      riosFsrRcp(max(abs(d-c),abs(c-b))),riosFsrRcp(max(abs(e-c),abs(c-a)))));
  length += dot(strength,strength)*weight;
}

kernel void riosFsrPrepare(texture2d<float,access::read> input [[texture(0)]],
                           texture2d<float,access::write> output [[texture(1)]],
                           constant IOSToneResolveConstants& tone [[buffer(0)]],
                           uint2 pixel [[thread_position_in_grid]]) {
  if(any(pixel>=uint2(output.get_width(),output.get_height()))) return;
  float3 color = max(float3(0),input.read(pixel).rgb*tone.exposure+tone.brightness)*tone.contrast;
  output.write(float4(pow(riosAcesToneMap(color),float3(tone.gamma)),1),pixel);
}

kernel void riosFsrEasu(texture2d<float,access::read> input [[texture(0)]],
                        texture2d<float,access::write> output [[texture(1)]],
                        uint2 pixel [[thread_position_in_grid]]) {
  if(any(pixel>=uint2(output.get_width(),output.get_height()))) return;
  const float2 position = (float2(pixel)+0.5)*float2(input.get_width(),input.get_height())/
                          float2(output.get_width(),output.get_height())-0.5;
  const int2 base = int2(floor(position));
  const float2 fraction = fract(position);
  // The reference 12 taps: b c / e f g h / i j k l / n o.
  constexpr int2 offsets[12] = {int2(0,-1),int2(1,-1),int2(-1,0),int2(0,0),int2(1,0),int2(2,0),
                                int2(-1,1),int2(0,1),int2(1,1),int2(2,1),int2(0,2),int2(1,2)};
  float3 color[12]; float luma[12];
  for(uint i=0;i<12;++i) { color[i]=riosFsrLoad(input,base+offsets[i]); luma[i]=riosFsrLuma(color[i]); }
  float2 direction=0; float length=0;
  riosFsrDirection(direction,length,(1-fraction.x)*(1-fraction.y),luma[0],luma[2],luma[3],luma[4],luma[7]);
  riosFsrDirection(direction,length,fraction.x*(1-fraction.y),luma[1],luma[3],luma[4],luma[5],luma[8]);
  riosFsrDirection(direction,length,(1-fraction.x)*fraction.y,luma[3],luma[6],luma[7],luma[8],luma[10]);
  riosFsrDirection(direction,length,fraction.x*fraction.y,luma[4],luma[7],luma[8],luma[9],luma[11]);
  const float squared = dot(direction,direction);
  if(squared<1.0/32768.0) direction=float2(1,0);
  else direction*=as_type<float>(0x5f347d74u-(as_type<uint>(squared)>>1u));
  length*=0.5; length*=length;
  const float stretch=dot(direction,direction)*riosFsrRcp(max(abs(direction.x),abs(direction.y)));
  const float2 anisotropy=float2(1+(stretch-1)*length,1-0.5*length);
  const float lobe=0.5+(0.25-0.04-0.5)*length;
  float3 accumulated=0; float total=0;
  for(uint i=0;i<12;++i) {
    const float2 offset=float2(offsets[i])-fraction;
    const float2 rotated=float2(dot(offset,direction),dot(offset,float2(-direction.y,direction.x)))*anisotropy;
    const float distance=min(dot(rotated,rotated),riosFsrRcp(lobe));
    float baseWeight=0.4*distance-1, window=lobe*distance-1;
    baseWeight=1.5625*baseWeight*baseWeight-0.5625;
    const float weight=baseWeight*window*window;
    accumulated+=color[i]*weight; total+=weight;
  }
  const float3 low=min(min(color[3],color[4]),min(color[7],color[8]));
  const float3 high=max(max(color[3],color[4]),max(color[7],color[8]));
  output.write(float4(clamp(accumulated/total,low,high),1),pixel);
}

kernel void riosFsrRcas(texture2d<float,access::read> input [[texture(0)]],
                        texture2d<float,access::write> output [[texture(1)]],
                        uint2 pixel [[thread_position_in_grid]]) {
  if(any(pixel>=uint2(output.get_width(),output.get_height()))) return;
  const int2 p=int2(pixel);
  const float3 b=riosFsrLoad(input,p+int2(0,-1)), d=riosFsrLoad(input,p+int2(-1,0));
  const float3 e=riosFsrLoad(input,p), f=riosFsrLoad(input,p+int2(1,0)), h=riosFsrLoad(input,p+int2(0,1));
  const float3 low=min(min(b,d),min(f,h)), high=max(max(b,d),max(f,h));
  // Constant black/white channels have zero contrast and need no sharpening.
  const float3 hitMin=min(low,e)/max(4*high,float3(1e-6));
  const float3 hitMax=(1-max(high,e))/min(4*low-4,float3(-1e-6));
  const float3 limits=max(-hitMin,hitMax);
  const float lobe=max(-0.1875,min(max(max(limits.r,limits.g),limits.b),0.0))*0.5;
  output.write(float4(saturate((lobe*(b+d+f+h)+e)/(4*lobe+1)),1),pixel);
}

fragment float4 riosSceneCopyFragment(IOSToneResolveVertexOut in [[stage_in]],
                                      texture2d<float,access::read> input [[texture(0)]]) {
  const float noise=(riosInterleavedGradientNoise(in.position.xy)*2-1)/255.0;
  return float4(input.read(uint2(in.position.xy)).rgb+noise,1);
}
