//
//  main.m
//  AudioQueueRecorder
//
//  Created by Xiao Quan on 12/13/21.
//

#import <Foundation/Foundation.h>
#include <AudioToolbox/AudioToolbox.h>

#define kNumberOfRecordBuffers 3

// MARK: - User Data Struct
/* 4.3 */
typedef struct Recorder {
    AudioFileID     recordFile;
    SInt64          recordPacket;
    Boolean         running;
} Recorder;

// MARK: - Utility Functions
/* 4.2 */
static void CheckError(OSStatus error, const char *operation) {
    if (error == noErr) return;
    
    char errorString[20];
    // Is error a four char code?
    *(UInt32 *) (errorString + 1) = CFSwapInt32BigToHost(error);
    if (isprint(errorString[1]) &&
        isprint(errorString[2]) &&
        isprint(errorString[3]) &&
        isprint(errorString[4])) {
        errorString[0] = errorString[5] = '\'';
        errorString[6] = '\0';
    } else {
        // Format error as an integer
        sprintf(errorString, "%d", (int) error);
    }
    fprintf(stderr, "Error: %s (%s) \n", operation, errorString);
    
    exit(1);
}

/* 4.20, 21 */
OSStatus GetDefaultInputDeviceSampleRate(Float64 *outSampleRate) {
    OSStatus error;
    AudioDeviceID deviceID = 0;
    
    AudioObjectPropertyAddress propertyAddress;
    UInt32 propertySize;
    propertyAddress.mSelector = kAudioHardwarePropertyDefaultInputDevice;
    propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propertyAddress.mElement = 0;
    propertySize = sizeof(AudioDeviceID);
    error = AudioHardwareServiceGetPropertyData(kAudioObjectSystemObject,
                                                &propertyAddress,
                                                0,
                                                NULL,
                                                &propertySize,
                                                &deviceID);
    if (error) return error;
    
    propertyAddress.mSelector = kAudioDevicePropertyNominalSampleRate;
    propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propertyAddress.mElement = 0;
    propertySize = sizeof(Float64);
    error = AudioHardwareServiceGetPropertyData(deviceID,
                                                &propertyAddress,
                                                0,
                                                NULL,
                                                &propertySize,
                                                outSampleRate);
    
    return error;
}

/* 4.22 */
static void CopyEncoderCookieToFile(AudioQueueRef queue,
                                    AudioFileID file) {
    OSStatus error;
    UInt32 propertySize;
    
    error = AudioQueueGetPropertySize(queue,
                                      kAudioConverterCompressionMagicCookie,
                                      &propertySize);
    
    if (error == noErr && propertySize > 0) {
        Byte *magicCookie = (Byte *) malloc(propertySize);
        CheckError(AudioQueueGetProperty(queue,
                                         kAudioQueueProperty_MagicCookie,
                                         magicCookie,
                                         &propertySize),
                   "AudioQueueGetProperty failed getting magic cookie from queue");
        CheckError(AudioFileSetProperty(file,
                                        kAudioFilePropertyMagicCookieData,
                                        propertySize,
                                        magicCookie),
                   "AudioFileSetProperty failed setting magic cookie to file");
        
        free(magicCookie);
    }
}

/* 4.23 */
static int ComputeRecordBufferSize(const AudioStreamBasicDescription *format,
                                   AudioQueueRef queue,
                                   float seconds) {
    int packets, frames, bytes;
    
    frames = (int) ceil(seconds * format->mSampleRate);
    
    if (format->mBytesPerFrame > 0) {
        bytes = frames * format->mBytesPerFrame;
    } else {
        UInt32 maxPacketSize;
        if (format->mBytesPerPacket > 0) {
            // Constant packet size
            maxPacketSize = format->mBytesPerPacket;
        } else {
            // Get the largest single packet
            UInt32 propertySize = sizeof(maxPacketSize);
            CheckError(AudioQueueGetProperty(queue,
                                             kAudioConverterPropertyMaximumOutputPacketSize,
                                             &maxPacketSize,
                                             &propertySize),
                       "AudioQueueGetProperty failed getting max packet size from queue");
        }
        if (format->mFramesPerPacket > 0) {
            packets = frames / format->mFramesPerPacket;
        } else {
            packets = frames;
        }
        
        if (packets == 0) packets = 1;
        
        bytes = packets * maxPacketSize;
    }
    
    return bytes;
}

// MARK: - Record Callback Function
// 4.24-26
static void AQInputCallback(void *inUserData,
                            AudioQueueRef inQueue,
                            AudioQueueBufferRef inBuffer,
                            const AudioTimeStamp *inStartTime,
                            UInt32 inNumPackets,
                            const AudioStreamPacketDescription *inPacketDesc) {
    Recorder *recorder = (Recorder *) inUserData;
    
    if (inNumPackets > 0) {
        // write packet to file
        CheckError(AudioFileWritePackets(recorder->recordFile,
                                         FALSE,
                                         inBuffer->mAudioDataByteSize,
                                         inPacketDesc,
                                         recorder->recordPacket,
                                         &inNumPackets,
                                         inBuffer),
                   "AudioFileWritePackets failed");
        
        recorder->recordPacket += inNumPackets;
    }
    
    if (recorder->running) {
        CheckError(AudioQueueEnqueueBuffer(inQueue,
                                           inBuffer,
                                           0,
                                           NULL),
                   "AudioQueueEnqueueBuffer failed");
    }
}

// MARK: - Main Function
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Set up format 4.4-4.7
        Recorder recorder = {0};
        AudioStreamBasicDescription recordFormat;
        memset(&recordFormat, 0, sizeof(recordFormat));
        
        recordFormat.mFormatID = kAudioFormatMPEG4AAC;
        recordFormat.mChannelsPerFrame = 2;
        
        GetDefaultInputDeviceSampleRate(&recordFormat.mSampleRate);
        
        UInt32 propSize = sizeof(recordFormat);
        CheckError(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                                          0,
                                          NULL,
                                          &propSize,
                                          &recordFormat),
                   "AudioFormatGetProperty failed");
        
        // Set up Queue 4.8-4.9
        AudioQueueRef queue = {0};
        CheckError(AudioQueueNewInput(&recordFormat,
                                      AQInputCallback,
                                      &recorder,
                                      NULL,
                                      NULL,
                                      0,
                                      &queue),
                   "AudioQueueNewInput failed");
        
        /* Retrieve filled ASBD from queue*/
        UInt32 size = sizeof(recordFormat);
        CheckError(AudioQueueGetProperty(queue,
                                         kAudioConverterCurrentOutputStreamDescription,
                                         &recordFormat,
                                         &size),
                   "failed to get asbd format from queue");
        
        // Set up file 4.10-4.11
        CFURLRef fileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                                         CFSTR("output.caf"),
                                                         kCFURLPOSIXPathStyle,
                                                         false);
        
        CheckError(AudioFileCreateWithURL(fileURL,
                                          kAudioFileCAFType,
                                          &recordFormat,
                                          kAudioFileFlags_EraseFile,
                                          &recorder.recordFile),
                   "AudioFileCreateWithURL failed");
        CFRelease(fileURL);
        
        /* Copy magic cookies if applicable */
        CopyEncoderCookieToFile(queue, recorder.recordFile);
        
        // Other set ups 4.12-4.13
        // Allocate and put buffers into queue
        int bufferByteSize = ComputeRecordBufferSize(&recordFormat, queue, 0.5);
        
        int bufferIndex;
        for (bufferIndex = 0;
             bufferIndex < kNumberOfRecordBuffers;
             bufferIndex++) {
            AudioQueueBufferRef buffer;
            CheckError(AudioQueueAllocateBuffer(queue,
                                                bufferByteSize,
                                                &buffer),
                       "AudioQueueAllocateBuffer failed");
            
            CheckError(AudioQueueEnqueueBuffer(queue,
                                               buffer,
                                               0,
                                               NULL),
                       "AudioQueueEnqueueBuffer failed");
        }
        
        // Start queue 4.14-4.15
        recorder.running = TRUE;
        CheckError(AudioQueueStart(queue,
                                   NULL),
                   "AudioQueueStart failed");
        
        printf("Recording, press <return> to stop: \n");
        getchar();
        
        // Stop queue 4.16 - 4.18
        printf("* recording done *\n");
        recorder.running = FALSE;
        CheckError(AudioQueueStop(queue,
                                  TRUE),
                   "AudioQueueStop failed");
        
        CopyEncoderCookieToFile(queue, recorder.recordFile);
        
        /* Clean up */
        AudioQueueDispose(queue,
                          TRUE);
        AudioFileClose(recorder.recordFile);
    }
    return 0;
}
