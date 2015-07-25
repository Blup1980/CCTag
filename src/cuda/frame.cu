#include <iostream>
#include <limits>
#include <assert.h>
#include <fstream>
#include <string.h>
#include <cuda_runtime.h>
#include "debug_macros.hpp"

#include "frame.h"
// #include "clamp.h"
// #include "frame_gaussian.h"

namespace popart {

using namespace std;

/*************************************************************
 * Frame
 *************************************************************/

Frame::Frame( uint32_t width, uint32_t height )
    : _h_debug_plane( 0 )
    , _h_debug_smooth( 0 )
    , _h_debug_dx( 0 )
    , _h_debug_dy( 0 )
    , _h_debug_mag( 0 )
    , _h_debug_map( 0 )
    , _h_debug_hyst_edges( 0 )
    , _h_debug_edges( 0 )
    , _texture( 0 )
    , _wait_for_upload( 0 )
    , _wait_done( 0 )
{
    cerr << "Allocating frame: " << width << "x" << height << endl;

#if 0
    _stream = 0;
#else
    POP_CUDA_STREAM_CREATE( &_stream );
#endif

    size_t pitch;
    POP_CUDA_MALLOC_PITCH( (void**)&_d_plane.data, &pitch, width, height );
    _d_plane.step = pitch;
    _d_plane.cols = width;
    _d_plane.rows = height;
    assert( pitch % _d_plane.elemSize() == 0 );

    POP_CUDA_MEMSET_ASYNC( _d_plane.data,
                           0,
                           _d_plane.step * _d_plane.rows,
                           _stream );
}

Frame::~Frame( )
{
    deleteUploadEvent( );

    delete [] _h_debug_plane;
    delete [] _h_debug_smooth;
    delete [] _h_debug_dx;
    delete [] _h_debug_dy;
    delete [] _h_debug_mag;
    delete [] _h_debug_map;
    delete [] _h_debug_hyst_edges;
    delete [] _h_debug_edges;
    delete _texture;

    POP_CUDA_FREE( _d_hysteresis_block_counter );
    POP_CUDA_FREE( _d_connect_component_block_counter );
    POP_CUDA_FREE( _d_plane.data );
    POP_CUDA_FREE( _d_intermediate.data );
    POP_CUDA_FREE( _d_smooth.data );
    POP_CUDA_FREE( _d_dx.data );
    POP_CUDA_FREE( _d_dy.data );
    POP_CUDA_FREE( _d_mag.data );
    POP_CUDA_FREE( _d_map.data );
    POP_CUDA_FREE( _d_hyst_edges.data );
    POP_CUDA_FREE( _d_edges.data );
    POP_CUDA_FREE( _d_ring_output.data );

    cerr << "Released frame: " << getWidth() << "x" << getHeight() << endl;
}

void Frame::upload( const unsigned char* image )
{
    cerr << "source w=" << _d_plane.cols
         << " source pitch=" << _d_plane.cols
         << " dest pitch=" << _d_plane.step
         << " height=" << _d_plane.rows
         << endl;
    POP_CUDA_MEMCPY_2D_ASYNC( _d_plane.data,
                              getPitch(),
                              image,
                              getWidth(),
                              getWidth(),
                              getHeight(),
                              cudaMemcpyHostToDevice, _stream );
}

void Frame::createTexture( FrameTexture::Kind kind )
{
    if( _texture ) delete _texture;

    _texture = new FrameTexture( _d_plane );
}

__global__
void cu_fill_from_frame( unsigned char* dst, uint32_t pitch, uint32_t width, uint32_t height, unsigned char* src, uint32_t spitch, uint32_t swidth, uint32_t sheight )
{
    uint32_t idy = blockIdx.y;
    uint32_t idx = blockIdx.x * 32 + threadIdx.x;
    if( idy >= height ) return;
    if( idx >= pitch ) return;

    dst[ idy * pitch + idx ] = src[ idy * spitch + idx ];
}

void Frame::fillFromFrame( Frame& src )
{
    cerr << "Entering " << __FUNCTION__ << endl;
    cerr << "    copying from src frame with " << src.getWidth() << "x" << src.getHeight() << endl;
    cerr << "    to dst plane           with " << getWidth() << "x" << getHeight() << endl;
    assert( _d_plane );
    dim3 grid;
    dim3 block;
    block.x = 32;
    grid.x  = getWidth() / 32;
    grid.y  = getHeight();

    cu_fill_from_frame
        <<<grid,block,0,_stream>>>
        ( _d_plane, getPitch(), getWidth(), getHeight(), src._d_plane, src.getPitch(), src.getWidth(), src.getHeight() );
    POP_CHK_CALL_IFSYNC;
}

__global__
// void cu_fill_from_texture( unsigned char* dst, uint32_t pitch, uint32_t width, uint32_t height, cudaTextureObject_t tex )
void cu_fill_from_texture( cv::cuda::PtrStepSzb dst, cudaTextureObject_t tex )
{
    uint32_t idy = blockIdx.y;
    uint32_t idx = blockIdx.x * 32 + threadIdx.x;
    if( idy >= dst.rows ) return;
    if( idx >= dst.step ) return;
    bool nix = ( idx < dst.cols );
    float d = tex2D<float>( tex, float(idx)/float(dst.cols), float(idy)/float(dst.rows) );
    dst.ptr(idy)[idx] = nix ? (unsigned char)( d * 255 ) : 0;
}

void Frame::fillFromTexture( Frame& src )
{
    dim3 grid;
    dim3 block;
    block.x = 32;
    grid.x  = ( getWidth() / 32 ) + ( getWidth() % 32 == 0 ? 0 : 1 );
    grid.y  = getHeight();

    cu_fill_from_texture
        <<<grid,block,0,_stream>>>
        // ( _d_plane, getPitch(), getWidth(), getHeight(), src.getTex() );
        ( _d_plane, src.getTex() );
    POP_CHK_CALL_IFSYNC;
}

void Frame::deleteTexture( )
{
    delete _texture;
    _texture = 0;
}

void Frame::allocUploadEvent( )
{
    _wait_for_upload = new FrameEvent;

    cudaError_t err;
    err = cudaEventCreateWithFlags( _wait_for_upload, cudaEventDisableTiming );
    POP_CUDA_FATAL_TEST( err, "Could not create a non-timing event: " );
}

void Frame::deleteUploadEvent( )
{
    if( not _wait_for_upload ) return;
    cudaEventDestroy( *_wait_for_upload );
    delete _wait_for_upload;
}

FrameEvent Frame::addUploadEvent( )
{
    cudaError_t err;
    err = cudaEventRecord( *_wait_for_upload, _stream );
    POP_CUDA_FATAL_TEST( err, "Could not insert an event into a stream: " );
    return *_wait_for_upload;
}

void Frame::allocDoneEvent( )
{
    _wait_done = new FrameEvent;

    cudaError_t err;
    err = cudaEventCreateWithFlags( _wait_done, cudaEventDisableTiming );
    POP_CUDA_FATAL_TEST( err, "Could not create a non-timing event: " );
}

void Frame::deleteDoneEvent( )
{
    if( not _wait_done ) return;
    cudaEventDestroy( *_wait_done );
    delete _wait_done;
}

FrameEvent Frame::addDoneEvent( )
{
    cudaError_t err;
    err = cudaEventRecord( *_wait_done, _stream );
    POP_CUDA_FATAL_TEST( err, "Could not insert an event into a stream: " );
    return *_wait_done;
}

void Frame::streamSync( )
{
    cudaStreamSynchronize( _stream );
}

void Frame::streamSync( FrameEvent ev )
{
    cudaStreamWaitEvent( _stream, ev, 0 );
}

/*************************************************************
 * FrameTexture
 *************************************************************/

void FrameTexture::makeTex_Normalized_uchar_to_float( const cv::cuda::PtrStepSzb& plane )
{
    memset( &_texDesc, 0, sizeof(cudaTextureDesc) );

    _texDesc.normalizedCoords = 1;                           // address 0..1 instead of 0..width/height
    _texDesc.addressMode[0]   = cudaAddressModeClamp;
    _texDesc.addressMode[1]   = cudaAddressModeClamp;
    _texDesc.addressMode[2]   = cudaAddressModeClamp;
    _texDesc.readMode         = cudaReadModeNormalizedFloat; // automatic conversion from uchar to float
    _texDesc.filterMode       = cudaFilterModeLinear;        // bilinear interpolation

    memset( &_resDesc, 0, sizeof(cudaResourceDesc) );
    _resDesc.resType                  = cudaResourceTypePitch2D;
    _resDesc.res.pitch2D.devPtr       = plane.data;
    _resDesc.res.pitch2D.desc.f       = cudaChannelFormatKindUnsigned;
    _resDesc.res.pitch2D.desc.x       = 8;
    _resDesc.res.pitch2D.desc.y       = 0;
    _resDesc.res.pitch2D.desc.z       = 0;
    _resDesc.res.pitch2D.desc.w       = 0;
    assert( plane.elemSize() == 1 );
    _resDesc.res.pitch2D.pitchInBytes = plane.step;
    _resDesc.res.pitch2D.width        = plane.cols;
    _resDesc.res.pitch2D.height       = plane.rows;

    cudaError_t err;
    err = cudaCreateTextureObject( &_texture, &_resDesc, &_texDesc, 0 );
    POP_CUDA_FATAL_TEST( err, "Could not create texture object: " );
}

FrameTexture::FrameTexture( const cv::cuda::PtrStepSzb& plane )
    : _kind( normalized_uchar_to_float )
{
    makeTex_Normalized_uchar_to_float( plane );
}

FrameTexture::~FrameTexture( )
{
    cudaError_t err;
    err = cudaDestroyTextureObject( _texture );
    POP_CUDA_FATAL_TEST( err, "Could not destroy texture object: " );
}

}; // namespace popart

