//
//  Renderer.m
//  XHMTLImageProcess
//
//  Created by Xinhou Jiang on 2019/12/9.
//  Copyright © 2019 Xinhou Jiang. All rights reserved.
//
#import <simd/simd.h>
#import <ModelIO/ModelIO.h>
#import "Renderer.h"
// Include header shared between C code here, which executes Metal API commands, and .metal files
#import "ShaderTypes.h"
static const NSUInteger MaxBuffersInFlight = 3;
@implementation Renderer
{
    dispatch_semaphore_t _inFlightSemaphore;
    id <MTLDevice> _device;
    id <MTLCommandQueue> _commandQueue;
    
    id <MTLBuffer> _dynamicUniformBuffer[MaxBuffersInFlight];
    id<MTLBuffer> _quadBuffer;
    
    id<MTLTexture> _colorMap;
    id<MTLTexture> sourceTexture;
    id<MTLTexture> destTexture;
    id<MTLTexture> depthTexture;
    
    id <MTLRenderPipelineState> _pipelineState;
    id<MTLRenderPipelineState> _quadPipeline;
    id<MTLRenderPipelineState> _postprocessPipeline;
    
    id <MTLDepthStencilState> _defaultDepthState;
    id <MTLDepthStencilState> _quadDepthState;
    
    MTLVertexDescriptor *_mtlVertexDescriptor;
    uint8_t _uniformBufferIndex;
    matrix_float4x4 _projectionMatrix;
    float _rotation;
    MTKMesh *_mesh;
    CGSize screenSize;
}

-(nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)view;
{
    self = [super init];
    if(self)
    {
        _device = view.device;
        _inFlightSemaphore = dispatch_semaphore_create(MaxBuffersInFlight);
        [self _loadMetalWithView:view];
        [self _loadAssets];
    }
    return self;
}

- (void)_loadMetalWithView:(nonnull MTKView *)view;
{
    view.depthStencilPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    view.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    view.sampleCount = 1;
    screenSize = view.frame.size;

    // 顶点流格式定义
    _mtlVertexDescriptor = [[MTLVertexDescriptor alloc] init];
    _mtlVertexDescriptor.attributes[VertexAttributePosition].format = MTLVertexFormatFloat3;
    _mtlVertexDescriptor.attributes[VertexAttributePosition].offset = 0;
    _mtlVertexDescriptor.attributes[VertexAttributePosition].bufferIndex = BufferIndexMeshPositions;
    _mtlVertexDescriptor.attributes[VertexAttributeTexcoord].format = MTLVertexFormatFloat2;
    _mtlVertexDescriptor.attributes[VertexAttributeTexcoord].offset = 0;
    _mtlVertexDescriptor.attributes[VertexAttributeTexcoord].bufferIndex = BufferIndexMeshGenerics;
    _mtlVertexDescriptor.layouts[BufferIndexMeshPositions].stride = 12;
    _mtlVertexDescriptor.layouts[BufferIndexMeshPositions].stepRate = 1;
    _mtlVertexDescriptor.layouts[BufferIndexMeshPositions].stepFunction = MTLVertexStepFunctionPerVertex;
    _mtlVertexDescriptor.layouts[BufferIndexMeshGenerics].stride = 8;
    _mtlVertexDescriptor.layouts[BufferIndexMeshGenerics].stepRate = 1;
    _mtlVertexDescriptor.layouts[BufferIndexMeshGenerics].stepFunction = MTLVertexStepFunctionPerVertex;

    id<MTLLibrary> defaultLibrary = [_device newDefaultLibrary];

    // default pipeline
    id <MTLFunction> vertexFunction = [defaultLibrary newFunctionWithName:@"vertexShader"];
    id <MTLFunction> fragmentFunction = [defaultLibrary newFunctionWithName:@"fragmentShader"];
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.label = @"MyPipeline";
    pipelineStateDescriptor.sampleCount = view.sampleCount;
    pipelineStateDescriptor.vertexFunction = vertexFunction;
    pipelineStateDescriptor.fragmentFunction = fragmentFunction;
    pipelineStateDescriptor.vertexDescriptor = _mtlVertexDescriptor;
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat;//MTLPixelFormatBGRA8Unorm
    pipelineStateDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat;//MTLPixelFormatDepth32Float
    pipelineStateDescriptor.stencilAttachmentPixelFormat = MTLPixelFormatInvalid;//MTLPixelFormatStencil8
    NSError *error = NULL;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
    if (!_pipelineState)
    {
        NSLog(@"Failed to created pipeline state, error %@", error);
    }
    
    // postprocess pipeline
    id <MTLFunction> postprocessFunction = [defaultLibrary newFunctionWithName:@"postProcessing"];
    MTLTileRenderPipelineDescriptor* tileRenderPipelineDescriptor = [MTLTileRenderPipelineDescriptor new];
    tileRenderPipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    tileRenderPipelineDescriptor.rasterSampleCount = 1;
    tileRenderPipelineDescriptor.threadgroupSizeMatchesTileSize = YES;
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
    depthStateDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthStateDesc.depthWriteEnabled = YES;
    _defaultDepthState = [_device newDepthStencilStateWithDescriptor:depthStateDesc];
    depthStateDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
    depthStateDesc.depthWriteEnabled = NO;
    _quadDepthState = [_device newDepthStencilStateWithDescriptor:depthStateDesc];
    depthStateDesc.depthWriteEnabled = YES;
    
    // RT定义
    MTLTextureDescriptor *texBufferDesc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                       width:screenSize.width
                                                      height:screenSize.height
                                                   mipmapped:NO];
    texBufferDesc.textureType = MTLTextureType2D;
    texBufferDesc.sampleCount = 1;
    texBufferDesc.usage |= MTLTextureUsageRenderTarget;
    texBufferDesc.storageMode = MTLStorageModeShared;
    texBufferDesc.pixelFormat = view.depthStencilPixelFormat;
    depthTexture = [_device newTextureWithDescriptor:texBufferDesc];
    //texBufferDesc.pixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    //_depthData2 = [_device newTextureWithDescriptor:depthBufferDesc];
    texBufferDesc.pixelFormat = view.colorPixelFormat;
    texBufferDesc.storageMode = MTLStorageModePrivate;
    texBufferDesc.usage |= MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    sourceTexture = [_device newTextureWithDescriptor:texBufferDesc];
    sourceTexture.label = @"sourceTexture";
    destTexture = [_device newTextureWithDescriptor:texBufferDesc];
    destTexture.label = @"sourceTexture";

    // Triple buffer
    for(NSUInteger i = 0; i < MaxBuffersInFlight; i++)
    {
        _dynamicUniformBuffer[i] = [_device newBufferWithLength:sizeof(Uniforms)
                                                        options:MTLResourceStorageModeShared];
        _dynamicUniformBuffer[i].label = @"UniformBuffer";
    }
    _commandQueue = [_device newCommandQueue];
}

- (void)_loadAssets
{
    NSError *error;
    MTKMeshBufferAllocator *metalAllocator = [[MTKMeshBufferAllocator alloc]
                                              initWithDevice: _device];
    MDLMesh *mdlMesh = [MDLMesh newBoxWithDimensions:(vector_float3){4, 4, 4}
                                            segments:(vector_uint3){2, 2, 2}
                                        geometryType:MDLGeometryTypeTriangles
                                       inwardNormals:NO
                                           allocator:metalAllocator];
    MDLVertexDescriptor *mdlVertexDescriptor =
    MTKModelIOVertexDescriptorFromMetal(_mtlVertexDescriptor);
    mdlVertexDescriptor.attributes[VertexAttributePosition].name  = MDLVertexAttributePosition;
    mdlVertexDescriptor.attributes[VertexAttributeTexcoord].name  = MDLVertexAttributeTextureCoordinate;
    mdlMesh.vertexDescriptor = mdlVertexDescriptor;
    _mesh = [[MTKMesh alloc] initWithMesh:mdlMesh
                                   device:_device
                                    error:&error];
    if(!_mesh || error)
    {
        NSLog(@"Error creating MetalKit mesh %@", error.localizedDescription);
    }
    MTKTextureLoader* textureLoader = [[MTKTextureLoader alloc] initWithDevice:_device];
    NSDictionary *textureLoaderOptions =
    @{
      MTKTextureLoaderOptionTextureUsage       : @(MTLTextureUsageShaderRead),
      MTKTextureLoaderOptionTextureStorageMode : @(MTLStorageModePrivate)
      };
    _colorMap = [textureLoader newTextureWithName:@"lena"
                                      scaleFactor:1.0
                                           bundle:nil
                                          options:textureLoaderOptions
                                            error:&error];
    if(!_colorMap || error)
    {
        NSLog(@"Error creating texture %@", error.localizedDescription);
    }
}

- (void)_updateGameState
{
    /// Update any game state before encoding renderint commands to our drawable
    Uniforms * uniforms = (Uniforms*)_dynamicUniformBuffer[_uniformBufferIndex].contents;
    uniforms->projectionMatrix = _projectionMatrix;
    vector_float3 rotationAxis = {1, 1, 0};
    matrix_float4x4 modelMatrix = matrix4x4_rotation(_rotation, rotationAxis);
    matrix_float4x4 viewMatrix = matrix4x4_translation(0.0, 0.0, -8.0);
    uniforms->modelViewMatrix = matrix_multiply(viewMatrix, modelMatrix);
    _rotation += .01;
}

- (void)drawInMTKView:(nonnull MTKView *)view
{
    /// Per frame updates here
    dispatch_semaphore_wait(_inFlightSemaphore, DISPATCH_TIME_FOREVER);
    _uniformBufferIndex = (_uniformBufferIndex + 1) % MaxBuffersInFlight;
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"MyCommand";
    __block dispatch_semaphore_t block_sema = _inFlightSemaphore;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer)
     {
         dispatch_semaphore_signal(block_sema);
     }];
    [self _updateGameState];

    // 绘制图形到RT
    MTLRenderPassDescriptor* renderPassDescriptor = [MTLRenderPassDescriptor new];
    renderPassDescriptor.colorAttachments[0].texture = sourceTexture;
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    renderPassDescriptor.depthAttachment.texture = depthTexture;
    renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
    renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionStore;
    if(renderPassDescriptor != nil)
    {
        id <MTLRenderCommandEncoder> renderEncoder =
        [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        renderEncoder.label = @"MyRenderEncoder";

        [renderEncoder pushDebugGroup:@"DrawBox"];
        [renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [renderEncoder setCullMode:MTLCullModeBack];
        [renderEncoder setRenderPipelineState:_pipelineState];
        [renderEncoder setDepthStencilState:_defaultDepthState];
        [renderEncoder setVertexBuffer:_dynamicUniformBuffer[_uniformBufferIndex]
                                offset:0
                               atIndex:BufferIndexUniforms];
        [renderEncoder setFragmentBuffer:_dynamicUniformBuffer[_uniformBufferIndex]
                                  offset:0
                                 atIndex:BufferIndexUniforms];
        for (NSUInteger bufferIndex = 0; bufferIndex < _mesh.vertexBuffers.count; bufferIndex++)
        {
            MTKMeshBuffer *vertexBuffer = _mesh.vertexBuffers[bufferIndex];
            if((NSNull*)vertexBuffer != [NSNull null])
            {
                [renderEncoder setVertexBuffer:vertexBuffer.buffer
                                        offset:vertexBuffer.offset
                                       atIndex:bufferIndex];
            }
        }
        [renderEncoder setFragmentTexture:_colorMap
                                  atIndex:TextureIndexColor];
        for(MTKSubmesh *submesh in _mesh.submeshes)
        {
            [renderEncoder drawIndexedPrimitives:submesh.primitiveType
                                      indexCount:submesh.indexCount
                                       indexType:submesh.indexType
                                     indexBuffer:submesh.indexBuffer.buffer
                               indexBufferOffset:submesh.indexBuffer.offset];
        }
        [renderEncoder popDebugGroup];
        
        // 后处理
        renderPassDescriptor.tileWidth = 16;
        renderPassDescriptor.tileHeight = 16;
        [renderEncoder setRenderPipelineState:_postprocessPipeline];
        [renderEncoder setTileTexture:sourceTexture atIndex:0];
        [renderEncoder setTileTexture:destTexture atIndex:1];
        [renderEncoder dispatchThreadsPerTile:MTLSizeMake(32, 32, 1)];
        
        [renderEncoder endEncoding];
    }

    // 绘制RT到屏幕上
    MTLRenderPassDescriptor* curRenderDescriptor = view.currentRenderPassDescriptor;
    if(curRenderDescriptor !=  nil)
    {
        id<MTLRenderCommandEncoder> myRenderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:curRenderDescriptor];
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
    /// Respond to drawable size or orientation changes here
    screenSize = size;
    float aspect = size.width / (float)size.height;
    _projectionMatrix = matrix_perspective_right_hand(65.0f * (M_PI / 180.0f), aspect, 0.1f, 100.0f);
}

#pragma mark Matrix Math Utilities
matrix_float4x4 matrix4x4_translation(float tx, float ty, float tz)
{
    return (matrix_float4x4) {{
        { 1,   0,  0,  0 },
        { 0,   1,  0,  0 },
        { 0,   0,  1,  0 },
        { tx, ty, tz,  1 }
    }};
}
static matrix_float4x4 matrix4x4_rotation(float radians, vector_float3 axis)
{
    axis = vector_normalize(axis);
    float ct = cosf(radians);
    float st = sinf(radians);
    float ci = 1 - ct;
    float x = axis.x, y = axis.y, z = axis.z;

    return (matrix_float4x4) {{
        { ct + x * x * ci,     y * x * ci + z * st, z * x * ci - y * st, 0},
        { x * y * ci - z * st,     ct + y * y * ci, z * y * ci + x * st, 0},
        { x * z * ci + y * st, y * z * ci - x * st,     ct + z * z * ci, 0},
        {                   0,                   0,                   0, 1}
    }};
}
matrix_float4x4 matrix_perspective_right_hand(float fovyRadians, float aspect, float nearZ, float farZ)
{
    float ys = 1 / tanf(fovyRadians * 0.5);
    float xs = ys / aspect;
    float zs = farZ / (nearZ - farZ);

    return (matrix_float4x4) {{
        { xs,   0,          0,  0 },
        {  0,  ys,          0,  0 },
        {  0,   0,         zs, -1 },
        {  0,   0, nearZ * zs,  0 }
    }};
}
@end
