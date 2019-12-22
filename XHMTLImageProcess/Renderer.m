//
//  Renderer.m
//  XHMTLImageProcess
//
//  Created by Xinhou Jiang on 2019/12/9.
//  Copyright © 2019 Xinhou Jiang. All rights reserved.
//
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import "Renderer.h"
// Include header shared between C code here, which executes Metal API commands, and .metal files
#import "ShaderTypes.h"
@implementation Renderer
{
    id <MTLDevice> _device;
    id <MTLCommandQueue> _commandQueue;
    
    id<MTLBuffer> _quadBuffer;
    id<MTLBuffer> _accHistogramBuffer; // 直方图
    
    id<MTLTexture> sourceTexture;
    id<MTLTexture> destTexture;
    
    id<MTLRenderPipelineState> _pipelineState;
    id<MTLRenderPipelineState> _quadPipeline;
    id<MTLRenderPipelineState> _postprocessPipeline;
    id<MTLRenderPipelineState> _clearHistogramPipeline;
    id<MTLRenderPipelineState> _calHistogramPipeline;
    
    id <MTLDepthStencilState> _quadDepthState;
    CGSize screenSize;
    
    NSString *imageName;
}

-(nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)view;
{
    self = [super init];
    if(self)
    {
        _device = view.device;
        imageName = @"lenatest";
        [self _loadAssets];
        [self _loadMetalWithView:view];
    }
    return self;
}

- (void)_loadMetalWithView:(nonnull MTKView *)view;
{
    view.depthStencilPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    view.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    view.sampleCount = 1;
    screenSize = view.frame.size;

    id<MTLLibrary> defaultLibrary = [_device newDefaultLibrary];
    
    MTLTileRenderPipelineDescriptor* tileRenderPipelineDescriptor = [MTLTileRenderPipelineDescriptor new];
    tileRenderPipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    tileRenderPipelineDescriptor.rasterSampleCount = view.sampleCount;
    tileRenderPipelineDescriptor.threadgroupSizeMatchesTileSize = YES;
    
    // postprocess pipeline
    id <MTLFunction> postprocessFunction = [defaultLibrary newFunctionWithName:@"postProcessing"];
    tileRenderPipelineDescriptor.tileFunction = postprocessFunction;
    _postprocessPipeline = [_device newRenderPipelineStateWithTileDescriptor:tileRenderPipelineDescriptor options:0 reflection:nil error:nil];
    /*
    id <MTLFunction> clearHistogramFunction = [defaultLibrary newFunctionWithName:@"clearBuffer"];
    tileRenderPipelineDescriptor.tileFunction = clearHistogramFunction;
    _clearHistogramPipeline = [_device newRenderPipelineStateWithTileDescriptor:tileRenderPipelineDescriptor options:0 reflection:nil error:nil];
    
    id <MTLFunction> calHistogramFunction = [defaultLibrary newFunctionWithName:@"calHistogram"];
    tileRenderPipelineDescriptor.tileFunction = calHistogramFunction;
    _calHistogramPipeline = [_device newRenderPipelineStateWithTileDescriptor:tileRenderPipelineDescriptor options:0 reflection:nil error:nil];
    */
    // quad buffer
    static const AAPLVertex verts[] =
    {
        // Pixel positions, Texture coordinates
        { {  1.0,  -1.0 },  { 1.f, 1.f } },
        { { -1.0,  -1.0 },  { 0.f, 1.f } },
        { { -1.0,   1.0 },  { 0.f, 0.f } },
        
        { {  1.0,  -1.0 },  { 1.f, 1.f } },
        { { -1.0,   1.0 },  { 0.f, 0.f } },
        { {  1.0,   1.0 },  { 1.f, 0.f } },
    };
    _quadBuffer = [_device newBufferWithBytes:verts length:sizeof(verts) options:MTLResourceStorageModeShared];
    _quadBuffer.label = @"QuadVB";
    
    /*
    // 直方图统计
    HistogramColor histogramData[256];
    for (int i = 0; i < 256; ++i) {
        histogramData[i].hr = 0;
        histogramData[i].hg = 0;
        histogramData[i].hb = 0;
    }
    UIImage *image = [UIImage imageNamed:imageName];
    Byte *colors = (Byte *)[image CGImage];
    for (int i = 0; i< sourceTexture.width * sourceTexture.height; ++i) {
        histogramData[colors[i * 4 + 0]].hr++;
        histogramData[colors[i * 4 + 1]].hg++;
        histogramData[colors[i * 4 + 2]].hb++;
    }
    
    // 累加直方图
    HistogramColor accHistogramData[256];
    accHistogramData[0].hr = histogramData[0].hr;
    accHistogramData[0].hg = histogramData[0].hg;
    accHistogramData[0].hb = histogramData[0].hb;
    for (int i = 1; i < 256; ++i) {
        accHistogramData[i].hr = accHistogramData[i-1].hr + histogramData[i].hr;
        accHistogramData[i].hg = accHistogramData[i-1].hg + histogramData[i].hg;
        accHistogramData[i].hb = accHistogramData[i-1].hb + histogramData[i].hb;
    }
    _accHistogramBuffer = [_device newBufferWithBytes:accHistogramData length:sizeof(accHistogramData) options:MTLResourceStorageModeShared];
    */
    id<MTLFunction> vertexQuadFunction = [defaultLibrary newFunctionWithName:@"vertexQuadMain"];
    id<MTLFunction> fragmentQuadFunction = [defaultLibrary newFunctionWithName:@"fragmentQuadMain"];
    MTLRenderPipelineDescriptor *pipeDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipeDesc.label = @"QuadPileLine";
    pipeDesc.vertexFunction        = vertexQuadFunction;
    pipeDesc.fragmentFunction    = fragmentQuadFunction;
    pipeDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    pipeDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat;
    pipeDesc.stencilAttachmentPixelFormat = view.depthStencilPixelFormat;
    _quadPipeline = [_device newRenderPipelineStateWithDescriptor:pipeDesc error:nil];
    
    // 深度状态对象
    MTLDepthStencilDescriptor *depthStateDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthStateDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
    depthStateDesc.depthWriteEnabled = NO;
    _quadDepthState = [_device newDepthStencilStateWithDescriptor:depthStateDesc];
    
    // destTexture
    MTLTextureDescriptor *texBufferDesc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                                       width:screenSize.width
                                                      height:screenSize.height
                                                   mipmapped:NO];
    texBufferDesc.textureType = MTLTextureType2D;
    texBufferDesc.sampleCount = view.sampleCount;
    texBufferDesc.pixelFormat = view.colorPixelFormat;
    texBufferDesc.storageMode = MTLStorageModePrivate;
    texBufferDesc.usage |= MTLTextureUsageRenderTarget | MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    destTexture = [_device newTextureWithDescriptor:texBufferDesc];
    destTexture.label = @"sourceTexture";

    _commandQueue = [_device newCommandQueue];
}

// 加载要处理的图像
- (void)_loadAssets
{
    NSError *error;
    MTKTextureLoader* textureLoader = [[MTKTextureLoader alloc] initWithDevice:_device];
    NSDictionary *textureLoaderOptions =
    @{
      MTKTextureLoaderOptionTextureUsage       : @(MTLTextureUsageShaderRead),
      MTKTextureLoaderOptionTextureStorageMode : @(MTLStorageModePrivate)
      };
    sourceTexture = [textureLoader newTextureWithName:imageName
                                      scaleFactor:1.0
                                           bundle:nil
                                          options:textureLoaderOptions
                                            error:&error];
    if(!sourceTexture || error)
    {
        NSLog(@"Error creating texture %@", error.localizedDescription);
    }
    
}

- (void)drawInMTKView:(nonnull MTKView *)view
{
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"MyCommand";

    MTLRenderPassDescriptor* curRenderDescriptor = view.currentRenderPassDescriptor;
    curRenderDescriptor.tileWidth = 32;
    curRenderDescriptor.tileHeight = 32;
    if(curRenderDescriptor !=  nil)
    {
        // 计算直方图数据
        MPSImageHistogramInfo info;
        info.histogramForAlpha = true;
        info.numberOfHistogramEntries = 256;
        info.minPixelValue = simd_make_float4(0, 0, 0, 0);
        info.maxPixelValue = simd_make_float4(1, 1, 1, 1);
        MPSImageHistogram *histogram = [[MPSImageHistogram alloc] initWithDevice:_device histogramInfo:&info];
        size_t length = [histogram histogramSizeForSourceFormat:sourceTexture.pixelFormat];
        id<MTLBuffer> histogramInfoBuffer = [_device newBufferWithLength:length options:MTLResourceStorageModePrivate];
        [histogram encodeToCommandBuffer:commandBuffer sourceTexture:sourceTexture histogram:histogramInfoBuffer histogramOffset:0];
        // 定义直方图均衡化对象
        MPSImageHistogramEqualization *equalization = [[MPSImageHistogramEqualization alloc] initWithDevice:_device histogramInfo:&info];
        // 根据直方图计算累加直方图数据
        [equalization encodeTransformToCommandBuffer:commandBuffer sourceTexture:sourceTexture histogram:histogramInfoBuffer histogramOffset:0];
        // 最后进行均衡化处理
        [equalization encodeToCommandBuffer:commandBuffer sourceImage:sourceTexture destinationImage:destTexture];
        
        id<MTLRenderCommandEncoder> myRenderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:curRenderDescriptor];
        
        /*
        // Histogram
        [myRenderEncoder pushDebugGroup:@"clearBuffer"];
        [myRenderEncoder setRenderPipelineState:_clearHistogramPipeline];
        [myRenderEncoder setTileBuffer:_accHistogramBuffer offset:0 atIndex:0];
        [myRenderEncoder dispatchThreadsPerTile:MTLSizeMake(32, 32, 1)];
        [myRenderEncoder popDebugGroup];
        [myRenderEncoder pushDebugGroup:@"calHistogram"];
        [myRenderEncoder setRenderPipelineState:_calHistogramPipeline];
        [myRenderEncoder setTileTexture:sourceTexture atIndex:0];
        [myRenderEncoder setTileBuffer:_accHistogramBuffer offset:0 atIndex:0];
        [myRenderEncoder dispatchThreadsPerTile:MTLSizeMake(32, 32, 1)];
        [myRenderEncoder popDebugGroup];
        
        // 图像处理
        [myRenderEncoder pushDebugGroup:@"ImageProcess"];
        [myRenderEncoder setRenderPipelineState:_postprocessPipeline];
        [myRenderEncoder setTileTexture:sourceTexture atIndex:0];
        [myRenderEncoder setTileTexture:destTexture atIndex:1];
        [myRenderEncoder setTileBuffer:_accHistogramBuffer offset:0 atIndex:0];
        [myRenderEncoder dispatchThreadsPerTile:MTLSizeMake(32, 32, 1)];
        [myRenderEncoder popDebugGroup];
         */
        
        // 绘制RT到屏幕上
        [myRenderEncoder pushDebugGroup:@"DrawQuad"];
        [myRenderEncoder setDepthStencilState:_quadDepthState];
        [myRenderEncoder setCullMode:MTLCullModeNone];
        [myRenderEncoder setRenderPipelineState:_quadPipeline];
        [myRenderEncoder setVertexBuffer:_quadBuffer offset:0 atIndex:0];
        [myRenderEncoder setFragmentTexture:destTexture atIndex:0];
        [myRenderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [myRenderEncoder popDebugGroup];
        [myRenderEncoder endEncoding];
        [commandBuffer presentDrawable:view.currentDrawable];
    }
    [commandBuffer commit];
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
    screenSize = size;
}
@end
