/*
 * AVFoundation input device
 * Copyright (c) 2014 Thilo Borgmann <thilo.borgmann@mail.de>
 * Copyright (c) 2015 Daniel Ly <nalply@gmail.com>
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/**
 * @file
 * OSX vchat input device (based on AVFoundation)
 */

#import <AVFoundation/AVFoundation.h>
#include <pthread.h>

#include "libavutil/pixdesc.h"
#include "libavutil/opt.h"
#include "libavutil/avstring.h"
#include "libavformat/internal.h"
#include "libavutil/internal.h"
#include "libavutil/parseutils.h"
#include "libavutil/time.h"
#include "avdevice.h"

static const int avf_time_base = 1000000;

static const AVRational avf_time_base_q = {
    .num = 1,
    .den = avf_time_base
};

struct AVFPixelFormatSpec {
    enum AVPixelFormat ff_id;
    OSType avf_id;
};

static const struct AVFPixelFormatSpec avf_pixel_formats[] = {
    { AV_PIX_FMT_MONOBLACK,    kCVPixelFormatType_1Monochrome },
    { AV_PIX_FMT_RGB555BE,     kCVPixelFormatType_16BE555 },
    { AV_PIX_FMT_RGB555LE,     kCVPixelFormatType_16LE555 },
    { AV_PIX_FMT_RGB565BE,     kCVPixelFormatType_16BE565 },
    { AV_PIX_FMT_RGB565LE,     kCVPixelFormatType_16LE565 },
    { AV_PIX_FMT_RGB24,        kCVPixelFormatType_24RGB },
    { AV_PIX_FMT_BGR24,        kCVPixelFormatType_24BGR },
    { AV_PIX_FMT_0RGB,         kCVPixelFormatType_32ARGB },
    { AV_PIX_FMT_BGR0,         kCVPixelFormatType_32BGRA },
    { AV_PIX_FMT_0BGR,         kCVPixelFormatType_32ABGR },
    { AV_PIX_FMT_RGB0,         kCVPixelFormatType_32RGBA },
    { AV_PIX_FMT_BGR48BE,      kCVPixelFormatType_48RGB },
    { AV_PIX_FMT_UYVY422,      kCVPixelFormatType_422YpCbCr8 },
    { AV_PIX_FMT_YUVA444P,     kCVPixelFormatType_4444YpCbCrA8R },
    { AV_PIX_FMT_YUVA444P16LE, kCVPixelFormatType_4444AYpCbCr16 },
    { AV_PIX_FMT_YUV444P,      kCVPixelFormatType_444YpCbCr8 },
    { AV_PIX_FMT_YUV422P16,    kCVPixelFormatType_422YpCbCr16 },
    { AV_PIX_FMT_YUV422P10,    kCVPixelFormatType_422YpCbCr10 },
    { AV_PIX_FMT_YUV444P10,    kCVPixelFormatType_444YpCbCr10 },
    { AV_PIX_FMT_YUV420P,      kCVPixelFormatType_420YpCbCr8Planar },
    { AV_PIX_FMT_NV12,         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange },
    { AV_PIX_FMT_YUYV422,      kCVPixelFormatType_422YpCbCr8_yuvs },
#if !TARGET_OS_IPHONE && __MAC_OS_X_VERSION_MIN_REQUIRED >= 1080
    { AV_PIX_FMT_GRAY8,        kCVPixelFormatType_OneComponent8 },
#endif
    { AV_PIX_FMT_NONE, 0 }
};

typedef struct
{
    AVClass*        class;

    int             frames_captured;
    int64_t         first_pts;
    pthread_mutex_t frame_lock;
    pthread_cond_t  frame_wait_cond;
    id              avf_delegate;

    AVRational      framerate;
    int             width, height;

    int             list_devices;
    int             video_device_index;
    int             video_stream_index;
    char            *video_filename;
    int             num_video_devices;

    enum AVPixelFormat pixel_format;

    AVCaptureSession         *capture_session;
    AVCaptureVideoDataOutput *video_output;
    CMSampleBufferRef         current_frame;
} AVFContext;

static void lock_frames(AVFContext* ctx)
{
    pthread_mutex_lock(&ctx->frame_lock);
}

static void unlock_frames(AVFContext* ctx)
{
    pthread_mutex_unlock(&ctx->frame_lock);
}

/** FrameReciever class - delegate for AVCaptureSession
 */
@interface AVFFrameReceiver : NSObject
{
    AVFContext* _context;
}

- (id)initWithContext:(AVFContext*)context;

- (void)  captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)videoFrame
         fromConnection:(AVCaptureConnection *)connection;

@end

@implementation AVFFrameReceiver

- (id)initWithContext:(AVFContext*)context
{
    if (self = [super init]) {
        _context = context;
    }
    return self;
}

- (void)  captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)videoFrame
         fromConnection:(AVCaptureConnection *)connection
{
    lock_frames(_context);

    if (_context->current_frame != nil) {
        CFRelease(_context->current_frame);
    }

    _context->current_frame = (CMSampleBufferRef)CFRetain(videoFrame);

    pthread_cond_signal(&_context->frame_wait_cond);

    unlock_frames(_context);

    ++_context->frames_captured;
}

@end

static void destroy_context(AVFContext* ctx)
{
    [ctx->capture_session stopRunning];

    [ctx->capture_session release];
    [ctx->video_output    release];
    [ctx->avf_delegate    release];

    ctx->capture_session = NULL;
    ctx->video_output    = NULL;
    ctx->avf_delegate    = NULL;

    pthread_mutex_destroy(&ctx->frame_lock);
    pthread_cond_destroy(&ctx->frame_wait_cond);

    if (ctx->current_frame) {
        CFRelease(ctx->current_frame);
    }
}

static void parse_device_name(AVFormatContext *s)
{
    AVFContext *ctx = (AVFContext*)s->priv_data;
    char *tmp = av_strdup(s->filename);
    char *save;

    if (tmp[0] != ':') {
        ctx->video_filename = av_strtok(tmp,  ":", &save);
    }
}

/**
 * Configure the video device.
 *
 * Configure the video device using a run-time approach to access properties
 * since formats, activeFormat are available since  iOS >= 7.0 or OSX >= 10.7
 * and activeVideoMaxFrameDuration is available since i0S >= 7.0 and OSX >= 10.9.
 *
 * The NSUndefinedKeyException must be handled by the caller of this function.
 *
 */
static int configure_video_device(AVFormatContext *s, AVCaptureDevice *video_device)
{
    AVFContext *ctx = (AVFContext*)s->priv_data;

    double framerate = av_q2d(ctx->framerate);
    NSObject *range = nil;
    NSObject *format = nil;
    NSObject *selected_range = nil;
    NSObject *selected_format = nil;

    for (format in [video_device valueForKey:@"formats"]) {
        CMFormatDescriptionRef formatDescription;
        CMVideoDimensions dimensions;

        formatDescription = (CMFormatDescriptionRef) [format performSelector:@selector(formatDescription)];
        dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);

        if ((ctx->width == 0 && ctx->height == 0) ||
            (dimensions.width == ctx->width && dimensions.height == ctx->height)) {

            selected_format = format;

            for (range in [format valueForKey:@"videoSupportedFrameRateRanges"]) {
                double max_framerate;

                [[range valueForKey:@"maxFrameRate"] getValue:&max_framerate];
                if (fabs (framerate - max_framerate) < 0.01) {
                    selected_range = range;
                    break;
                }
            }
        }
    }

    if (!selected_format) {
        av_log(s, AV_LOG_ERROR, "Selected video size (%dx%d) is not supported by the device\n",
            ctx->width, ctx->height);
        goto unsupported_format;
    }

    if (!selected_range) {
        av_log(s, AV_LOG_ERROR, "Selected framerate (%f) is not supported by the device\n",
            framerate);
        goto unsupported_format;
    }

    if ([video_device lockForConfiguration:NULL] == YES) {
        NSValue *min_frame_duration = [selected_range valueForKey:@"minFrameDuration"];

        [video_device setValue:selected_format forKey:@"activeFormat"];
        [video_device setValue:min_frame_duration forKey:@"activeVideoMinFrameDuration"];
        [video_device setValue:min_frame_duration forKey:@"activeVideoMaxFrameDuration"];
    } else {
        av_log(s, AV_LOG_ERROR, "Could not lock device for configuration");
        return AVERROR(EINVAL);
    }

    return 0;

unsupported_format:

    av_log(s, AV_LOG_ERROR, "Supported modes:\n");
    for (format in [video_device valueForKey:@"formats"]) {
        CMFormatDescriptionRef formatDescription;
        CMVideoDimensions dimensions;

        formatDescription = (CMFormatDescriptionRef) [format performSelector:@selector(formatDescription)];
        dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);

        for (range in [format valueForKey:@"videoSupportedFrameRateRanges"]) {
            double min_framerate;
            double max_framerate;

            [[range valueForKey:@"minFrameRate"] getValue:&min_framerate];
            [[range valueForKey:@"maxFrameRate"] getValue:&max_framerate];
            av_log(s, AV_LOG_ERROR, "  %dx%d@[%f %f]fps\n",
                dimensions.width, dimensions.height,
                min_framerate, max_framerate);
        }
    }
    return AVERROR(EINVAL);
}

static int add_video_device(AVFormatContext *s, AVCaptureDevice *video_device)
{
    AVFContext *ctx = (AVFContext*)s->priv_data;
    int ret;
    NSError *error  = nil;
    AVCaptureInput* capture_input = nil;
    struct AVFPixelFormatSpec pxl_fmt_spec;
    NSNumber *pixel_format;
    NSDictionary *capture_dict;
    dispatch_queue_t queue;

    if (ctx->video_device_index < ctx->num_video_devices) {
        capture_input = (AVCaptureInput*) [[[AVCaptureDeviceInput alloc] initWithDevice:video_device error:&error] autorelease];
    } else {
        capture_input = (AVCaptureInput*) video_device;
    }

    if (!capture_input) {
        av_log(s, AV_LOG_ERROR, "Failed to create AV capture input device: %s\n",
               [[error localizedDescription] UTF8String]);
        return 1;
    }

    if ([ctx->capture_session canAddInput:capture_input]) {
        [ctx->capture_session addInput:capture_input];
    } else {
        av_log(s, AV_LOG_ERROR, "can't add video input to capture session\n");
        return 1;
    }

    // Attaching output
    ctx->video_output = [[AVCaptureVideoDataOutput alloc] init];

    if (!ctx->video_output) {
        av_log(s, AV_LOG_ERROR, "Failed to init AV video output\n");
        return 1;
    }

    // Configure device framerate and video size
    @try {
        if ((ret = configure_video_device(s, video_device)) < 0) {
            return ret;
        }
    } @catch (NSException *exception) {
        if (![[exception name] isEqualToString:NSUndefinedKeyException]) {
          av_log (s, AV_LOG_ERROR, "An error occurred: %s", [exception.reason UTF8String]);
          return AVERROR_EXTERNAL;
        }
    }

    // select pixel format
    pxl_fmt_spec.ff_id = AV_PIX_FMT_NONE;

    for (int i = 0; avf_pixel_formats[i].ff_id != AV_PIX_FMT_NONE; i++) {
        if (ctx->pixel_format == avf_pixel_formats[i].ff_id) {
            pxl_fmt_spec = avf_pixel_formats[i];
            break;
        }
    }

    // check if selected pixel format is supported by AVFoundation
    if (pxl_fmt_spec.ff_id == AV_PIX_FMT_NONE) {
        av_log(s, AV_LOG_ERROR, "Selected pixel format (%s) is not supported by AVFoundation.\n",
               av_get_pix_fmt_name(pxl_fmt_spec.ff_id));
        return 1;
    }

    // check if the pixel format is available for this device
    if ([[ctx->video_output availableVideoCVPixelFormatTypes] indexOfObject:[NSNumber numberWithInt:pxl_fmt_spec.avf_id]] == NSNotFound) {
        av_log(s, AV_LOG_ERROR, "Selected pixel format (%s) is not supported by the input device.\n",
               av_get_pix_fmt_name(pxl_fmt_spec.ff_id));

        pxl_fmt_spec.ff_id = AV_PIX_FMT_NONE;

        av_log(s, AV_LOG_ERROR, "Supported pixel formats:\n");
        for (NSNumber *pxl_fmt in [ctx->video_output availableVideoCVPixelFormatTypes]) {
            struct AVFPixelFormatSpec pxl_fmt_dummy;
            pxl_fmt_dummy.ff_id = AV_PIX_FMT_NONE;
            for (int i = 0; avf_pixel_formats[i].ff_id != AV_PIX_FMT_NONE; i++) {
                if ([pxl_fmt intValue] == avf_pixel_formats[i].avf_id) {
                    pxl_fmt_dummy = avf_pixel_formats[i];
                    break;
                }
            }

            if (pxl_fmt_dummy.ff_id != AV_PIX_FMT_NONE) {
                av_log(s, AV_LOG_ERROR, "  %s\n", av_get_pix_fmt_name(pxl_fmt_dummy.ff_id));

                // select first supported pixel format instead of user selected (or default) pixel format
                if (pxl_fmt_spec.ff_id == AV_PIX_FMT_NONE) {
                    pxl_fmt_spec = pxl_fmt_dummy;
                }
            }
        }

        // fail if there is no appropriate pixel format or print a warning about overriding the pixel format
        if (pxl_fmt_spec.ff_id == AV_PIX_FMT_NONE) {
            return 1;
        } else {
            av_log(s, AV_LOG_WARNING, "Overriding selected pixel format to use %s instead.\n",
                   av_get_pix_fmt_name(pxl_fmt_spec.ff_id));
        }
    }

    ctx->pixel_format          = pxl_fmt_spec.ff_id;
    pixel_format = [NSNumber numberWithUnsignedInt:pxl_fmt_spec.avf_id];
    capture_dict = [NSDictionary dictionaryWithObject:pixel_format
                                               forKey:(id)kCVPixelBufferPixelFormatTypeKey];

    [ctx->video_output setVideoSettings:capture_dict];
    [ctx->video_output setAlwaysDiscardsLateVideoFrames:YES];

    ctx->avf_delegate = [[AVFFrameReceiver alloc] initWithContext:ctx];

    queue = dispatch_queue_create("avf_queue", NULL);
    [ctx->video_output setSampleBufferDelegate:ctx->avf_delegate queue:queue];
    dispatch_release(queue);

    if ([ctx->capture_session canAddOutput:ctx->video_output]) {
        [ctx->capture_session addOutput:ctx->video_output];
    } else {
        av_log(s, AV_LOG_ERROR, "can't add video output to capture session\n");
        return 1;
    }

    return 0;
}


static int get_video_config(AVFormatContext *s)
{
    AVFContext *ctx = (AVFContext*)s->priv_data;
    CVImageBufferRef image_buffer;
    CGSize image_buffer_size;
    AVStream* stream = avformat_new_stream(s, NULL);

    if (!stream) {
        return 1;
    }

    // Take stream info from the first frame.
    while (ctx->frames_captured < 1) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, YES);
    }

    lock_frames(ctx);

    ctx->video_stream_index = stream->index;

    avpriv_set_pts_info(stream, 64, 1, avf_time_base);

    image_buffer      = CMSampleBufferGetImageBuffer(ctx->current_frame);
    image_buffer_size = CVImageBufferGetEncodedSize(image_buffer);

    stream->codec->codec_id   = AV_CODEC_ID_RAWVIDEO;
    stream->codec->codec_type = AVMEDIA_TYPE_VIDEO;
    stream->codec->width      = (int)image_buffer_size.width;
    stream->codec->height     = (int)image_buffer_size.height;
    stream->codec->pix_fmt    = ctx->pixel_format;

    CFRelease(ctx->current_frame);
    ctx->current_frame = nil;

    unlock_frames(ctx);

    return 0;
}


static int avf_add_device_info(AVDeviceInfoList *list, AVFormatContext *s,
    int index, const char *description, const char *model, int do_log)
{
    if (do_log) av_log(s->priv_data, AV_LOG_INFO, "[%d] %s\n", index, description);
    if (!list) return 0;

    AVDeviceInfo *info = av_mallocz(sizeof(AVDeviceInfo));
    if (!info) return AVERROR(ENOMEM);

    info->device_name = av_asprintf("[%d] %s: %s", index, description, model);
    info->device_description = strdup(description);
    if (!info->device_name || !info->device_description) {
        av_free(info);
        return AVERROR(ENOMEM);
    }

    av_dynarray_add(&list->devices, &list->nb_devices, info);
    return list ? list->nb_devices : AVERROR(ENOMEM);
}

/**
 * List AVFoundation video adevices into AVDeviceInfoList.
 *
 * @param s      format context.
 * @param list   device list or NULL (to log only).
 * @param do_log log the devices if true.
 */
static int avf_get_device_list2(struct AVFormatContext *s, struct AVDeviceInfoList *list, int do_log) 
{
    int result = 0, index;
    const char *localizedName, *modelID;

    if (do_log) av_log(s->priv_data, AV_LOG_INFO, "osxvchat video inputs:\n");
    NSArray *video_devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *device in video_devices) {
        @autoreleasepool {
            index         = [video_devices indexOfObject:device];
            localizedName = [[device localizedName] UTF8String];
            modelID       = [[device modelID] UTF8String];

            result = avf_add_device_info(list, s, index, localizedName, modelID, do_log);
            if (result < 0) break;
        }
    }
    [video_devices release];

    // Make the first device default if it exists.
    if (list) list->default_device = list->nb_devices > 0 ? 0 : -1;

    return result;
}

static int avf_get_device_list(struct AVFormatContext *s, struct AVDeviceInfoList *list) 
{
   return avf_get_device_list2(s, list, FALSE);
}

static int avf_read_header(AVFormatContext *s)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    AVFContext *ctx         = (AVFContext*)s->priv_data;
    AVCaptureDevice *video_device = nil;

    // Find capture device
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    ctx->num_video_devices = [devices count];

    ctx->first_pts          = av_gettime();

    pthread_mutex_init(&ctx->frame_lock, NULL);
    pthread_cond_init(&ctx->frame_wait_cond, NULL);

    // List devices if requested
    if (ctx->list_devices) {
        avf_get_device_list2(s, NULL, TRUE);
        goto fail;
    }

    // parse input filename for video and audio device
    parse_device_name(s);

    // check for device index given in filename
    if (ctx->video_device_index == -1 && ctx->video_filename) {
        sscanf(ctx->video_filename, "%d", &ctx->video_device_index);
    }

    if (ctx->video_device_index >= 0) {
        if (ctx->video_device_index < ctx->num_video_devices) {
            video_device = [devices objectAtIndex:ctx->video_device_index];
        } else {
            av_log(ctx, AV_LOG_ERROR, "Invalid device index\n");
            goto fail;
        }
    } 
    else if (ctx->video_filename && strncmp(ctx->video_filename, "none", 4)) {

        if (!strncmp(ctx->video_filename, "default", 7)) {
            video_device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        } else {
            // looking for video inputs
            for (AVCaptureDevice *device in devices) {
                if (!strncmp(ctx->video_filename, [[device localizedName] UTF8String], strlen(ctx->video_filename))) {
                    video_device = device;
                    break;
                }
            }

            if (!video_device) {
                av_log(ctx, AV_LOG_ERROR, "Video device not found\n");
                goto fail;
            }
        }
    }

    if (video_device) {
        av_log(s, AV_LOG_DEBUG, "'%s' opened\n", [[video_device localizedName] UTF8String]);
    }

    // Initialize capture session
    ctx->capture_session = [[AVCaptureSession alloc] init];

    if (video_device && add_video_device(s, video_device)) {
        goto fail;
    }

    [ctx->capture_session startRunning];

    if (video_device && get_video_config(s)) {
        goto fail;
    }

    [pool release];
    return 0;

fail:
    destroy_context(ctx);
    return AVERROR(EIO);
}


static int avf_read_packet(AVFormatContext *s, AVPacket *pkt)
{
    AVFContext* ctx = (AVFContext*)s->priv_data;

    do {
        CVImageBufferRef image_buffer;
        lock_frames(ctx);

        image_buffer = CMSampleBufferGetImageBuffer(ctx->current_frame);

        if (ctx->current_frame != nil) {
            void *data;
            if (av_new_packet(pkt, (int)CVPixelBufferGetDataSize(image_buffer)) < 0) {
                return AVERROR(EIO);
            }

            CMItemCount count;
            CMSampleTimingInfo timing_info;

            if (CMSampleBufferGetOutputSampleTimingInfoArray(ctx->current_frame, 1, &timing_info, &count) == noErr) {
                AVRational timebase_q = av_make_q(1, timing_info.presentationTimeStamp.timescale);
                pkt->pts = pkt->dts = av_rescale_q(timing_info.presentationTimeStamp.value, timebase_q, avf_time_base_q);
            }

            pkt->stream_index  = ctx->video_stream_index;
            pkt->flags        |= AV_PKT_FLAG_KEY;

            CVPixelBufferLockBaseAddress(image_buffer, 0);

            data = CVPixelBufferGetBaseAddress(image_buffer);
            memcpy(pkt->data, data, pkt->size);

            CVPixelBufferUnlockBaseAddress(image_buffer, 0);
            CFRelease(ctx->current_frame);
            ctx->current_frame = nil;
        } else {
            pkt->data = NULL;
            pthread_cond_wait(&ctx->frame_wait_cond, &ctx->frame_lock);
        }

        unlock_frames(ctx);
    } while (!pkt->data);

    return 0;
}

static int avf_close(AVFormatContext *s)
{
    AVFContext* ctx = (AVFContext*)s->priv_data;
    destroy_context(ctx);
    return 0;
}

static const AVOption options[] = {
    { "list_devices", "list available devices", offsetof(AVFContext, list_devices), AV_OPT_TYPE_INT, {.i64=0}, 0, 1, AV_OPT_FLAG_DECODING_PARAM, "list_devices" },
    { "true", "", 0, AV_OPT_TYPE_CONST, {.i64=1}, 0, 0, AV_OPT_FLAG_DECODING_PARAM, "list_devices" },
    { "false", "", 0, AV_OPT_TYPE_CONST, {.i64=0}, 0, 0, AV_OPT_FLAG_DECODING_PARAM, "list_devices" },
    { "video_device_index", "select video device by index for devices with same name (starts at 0)", offsetof(AVFContext, video_device_index), AV_OPT_TYPE_INT, {.i64 = -1}, -1, INT_MAX, AV_OPT_FLAG_DECODING_PARAM },
    { "pixel_format", "set pixel format", offsetof(AVFContext, pixel_format), AV_OPT_TYPE_PIXEL_FMT, {.i64 = AV_PIX_FMT_YUV420P}, 0, INT_MAX, AV_OPT_FLAG_DECODING_PARAM},
    { "framerate", "set frame rate", offsetof(AVFContext, framerate), AV_OPT_TYPE_VIDEO_RATE, {.str = "ntsc"}, 0, 0, AV_OPT_FLAG_DECODING_PARAM },
    { "video_size", "set video size", offsetof(AVFContext, width), AV_OPT_TYPE_IMAGE_SIZE, {.str = NULL}, 0, 0, AV_OPT_FLAG_DECODING_PARAM },

    { NULL },
};

static const AVClass avf_class = {
    .class_name = "OSX vchat input device",
    .item_name  = av_default_item_name,
    .option     = options,
    .version    = LIBAVUTIL_VERSION_INT,
    .category   = AV_CLASS_CATEGORY_DEVICE_VIDEO_INPUT,
};

AVInputFormat ff_osxvchat_demuxer = {
    .name            = "osxvchat",
    .long_name       = NULL_IF_CONFIG_SMALL("OSX vchat input device"),
    .priv_data_size  = sizeof(AVFContext),
    .read_header     = avf_read_header,
    .read_packet     = avf_read_packet,
    .read_close      = avf_close,
    .get_device_list = avf_get_device_list,
    .flags           = AVFMT_NOFILE,
    .priv_class      = &avf_class,
};
