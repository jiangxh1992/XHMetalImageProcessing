//
//  Histogram.metal
//  XHMTLImageProcess
//
//  Created by Xinhou Jiang on 2019/12/19.
//  Copyright © 2019 Xinhou Jiang. All rights reserved.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

kernel void clearBuffer(device atomic_int *histogram [[buffer(0)]])
{
    for(int i = 0; i < 256; ++i)
    {
        atomic_store_explicit(&histogram[0], 0, memory_order_relaxed);
    }
}

kernel void calHistogram(texture2d<float, access::read> source[[texture(0)]],
                         device atomic_int *histogram [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if(gid.x >= source.get_width() || gid.y >= source.get_height()) return;
    
    float4 source_color = source.read(gid);
    ushort grayLevel = (ushort)(source_color.r * 255);
    atomic_fetch_add_explicit(&histogram[grayLevel],1,memory_order_relaxed);
}

kernel void postProcessing(texture2d<float, access::read> source[[texture(0)]],
                           texture2d<float, access::write> dest[[texture(1)]],
                           device HistogramColor *accHistogram [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]
                           )
{
    if(gid.x >= source.get_width() || gid.y >= source.get_height()) return;
    
    float4 source_color = source.read(gid);
    
    ushort grayLevel = (ushort)(source_color.x * 255);
    
    /* 直方图均衡化 */
    int M = source.get_width();
    int N = source.get_height();
    // 均衡化直方图sk
    HistogramColor sk[256];
    float size = M * N;
    for(int i = 1;i<256;++i){
        sk[i].hr = round(255.0 * (accHistogram[i].hr / size));
        sk[i].hg = round(255.0 * (accHistogram[i].hg / size));
        sk[i].hb = round(255.0 * (accHistogram[i].hb / size));
    }
    float r = sk[grayLevel].hr / 255.0;
    float g = sk[grayLevel].hg / 255.0;
    float b = sk[grayLevel].hb / 255.0;
    
    float4 result_color = float4(r,g,b,0);
    
    dest.write(result_color, gid);
}
