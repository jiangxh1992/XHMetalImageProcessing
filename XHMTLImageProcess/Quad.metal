//
//  File.metal
//  Unity-iPhone
//
//  Created by Xinhou Jiang on 2019/9/9.
//

#include <metal_stdlib>
using namespace metal;
#import "ShaderTypes.h"

struct VSOutput
{
    float4 pos [[position]];
    float2 texcoord;
};
struct FSOutput
{
    half4 frag_data [[color(0)]];
};
vertex VSOutput vertexQuadMain(uint vertexID [[ vertex_id]],
                               constant AAPLVertex *vertexArr [[buffer(0)]])
{
    VSOutput out;
    out.pos = vector_float4(vertexArr[vertexID].position,0.0,1.0);
    out.pos.y = 1 - out.pos.y;
    out.texcoord = vertexArr[vertexID].textureCoordinate;
    return out;
}
fragment FSOutput fragmentQuadMain(VSOutput input [[stage_in]],
                                   texture2d<half> colorTexture [[ texture(0) ]])
{
    FSOutput out;
    constexpr sampler textureSampler (mag_filter::linear,
                                      min_filter::linear);
    
    // Sample the texture to obtain a color
    const half4 colorSample = colorTexture.sample(textureSampler, input.texcoord);
    
    // return the color of the texture
    out.frag_data = colorSample;//vector_half4(input.texcoord.x,input.texcoord.y,0,0);//
    return out;
}

kernel void postProcessing(texture2d<float, access::read> source[[texture(0)]],
                           texture2d<float, access::write> dest[[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]
                           )
{
    float4 source_color = source.read(gid);
    float4 result_color = float4(source_color.x,0,0,0); // post processing
    
    dest.write(result_color, gid);
}
