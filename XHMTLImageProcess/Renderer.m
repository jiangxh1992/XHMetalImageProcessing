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
    
    id<MTLTexture> sourceTexture;
    id<MTLTexture> destTexture;
    
    id<MTLRenderPipelineState> _pipelineState;
    id<MTLRenderPipelineState> _quadPipeline;
    id<MTLRenderPipelineState> _postprocessPipeline;
    
    id <MTLDepthStencilState> _quadDepthState;
    CGSize screenSize;
    MTLSize tileSize;
}

-(nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)view;
{
    self = [super init];
    if(self)
    {
        _device = view.device;
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
    tileSize = MTLSizeMake(32, 32, 1);

    id<MTLLibrary> defaultLibrary = [_device newDefaultLibrary];
    
    MTLTileRenderPipelineDescriptor* tileRenderPipelineDescriptor = [MTLTileRenderPipelineDescriptor new];
    tileRenderPipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    tileRenderPipelineDescriptor.rasterSampleCount = view.sampleCount;
    tileRenderPipelineDescriptor.threadgroupSizeMatchesTileSize = YES;
    
    // postprocess pipeline
    id <MTLFunction> postprocessFunction = [defaultLibrary newFunctionWithName:@"postProcessing"];
    tileRenderPipelineDescriptor.tileFunction = postprocessFunction;
    _postprocessPipeline = [_device newRenderPipelineStateWithTileDescriptor:tileRenderPipelineDescriptor options:0 reflection:nil error:nil];
    
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
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                       width:screenSize.width
                                                      height:screenSize.height
                                                   mipmapped:NO];
    texBufferDesc.textureType = MTLTextureType2D;
    texBufferDesc.sampleCount = view.sampleCount;
    texBufferDesc.pixelFormat = view.colorPixelFormat;
    texBufferDesc.storageMode = MTLStorageModePrivate;
    texBufferDesc.usage |= MTLTextureUsageRenderTarget | MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    destTexture = [_device newTextureWithDescriptor:texBufferDesc];
    destTexture.label = @"destTexture";

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
    sourceTexture = [textureLoader newTextureWithName:@"lena"
                                      scaleFactor:1.0
                                           bundle:nil
                                          options:textureLoaderOptions
                                            error:&error];
    sourceTexture.label = @"sourceTexture";
    if(!sourceTexture || error)
    {
        NSLog(@"Error creating texture %@", error.localizedDescription);
    }
}

- (void)drawInMTKView:(nonnull MTKView *)view
{
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"MyCommand";

    NSUInteger threadgroupLength = sizeof(int) * 256;
    MTLRenderPassDescriptor* curRenderDescriptor = view.currentRenderPassDescriptor;
    curRenderDescriptor.threadgroupMemoryLength = threadgroupLength;
    curRenderDescriptor.tileWidth = tileSize.width;
    curRenderDescriptor.tileHeight = tileSize.height;
    if(curRenderDescriptor !=  nil)
    {
        // MPS 高斯模糊
        //MPSImageGaussianBlur *gaussianBlur = [[MPSImageGaussianBlur alloc] initWithDevice:_device sigma:3];
        //[gaussianBlur encodeToCommandBuffer:commandBuffer sourceTexture:sourceTexture destinationTexture:destTexture];
        
        id<MTLRenderCommandEncoder> myRenderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:curRenderDescriptor];
        
        // 图像处理
        [myRenderEncoder pushDebugGroup:@"ImageProcess"];
        [myRenderEncoder setRenderPipelineState:_postprocessPipeline];
        [myRenderEncoder setTileTexture:sourceTexture atIndex:0];
        [myRenderEncoder setTileTexture:destTexture atIndex:1];
        [myRenderEncoder dispatchThreadsPerTile:tileSize];
        [myRenderEncoder popDebugGroup];
        
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
