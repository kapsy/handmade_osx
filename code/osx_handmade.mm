/*
    Licensed to the Apache Software Foundation (ASF) under one
    or more contributor license agreements.  See the NOTICE file
    distributed with this work for additional information
    regarding copyright ownership.  The ASF licenses this file
    to you under the Apache License, Version 2.0 (the
    "License"); you may not use this file except in compliance
    with the License.  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing,
    software distributed under the License is distributed on an
    "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
    KIND, either express or implied.  See the License for the
    specific language governing permissions and limitations
    under the License.
*/

/*

    TODO: (Kapsy) THIS IS NOT A FINAL PLATFORM LAYER!!!

    - Fullscreen support

    - Saved game locations
    - Getting a handle to our own executable file
    - Asset loading path
    - Threading (launch a thread)
    - Raw Input (support for multiple keyboards)
    - Sleep/timeBeginPeriod
    - ClipCursor() (for multimonitor support)
    - QueryCancelAutoplay
    - WM_ACTIVATEAPP (for when we are not the active application)
    - Blit speed improvements (BitBlt)
    - Hardware acceleration (OpenGL or Direct3D or BOTH??)
    - GetKeyboardLayout (for French keyboards, international WASD support)

    Just a partial list of stuff!!
*/

// TODO: (Kapsy) Implement the ASM version at github.com/itfrombit/osx_handmade
// See: http://clang.llvm.org/docs/LanguageExtensions.html#builtin-functions
#define rdtsc __builtin_readcyclecounter

// TODO: (Kapsy) Cocoa specifies internal mach struct member, the only way
// I know how to get around this is to include Cocoa.h first.
#include <Cocoa/Cocoa.h>

#include "handmade_platform.h"

#include <Carbon/Carbon.h>
#include <CoreGraphics/CoreGraphics.h>
#include <AudioUnit/AudioUnit.h>
#include <AudioToolbox/AudioToolbox.h>

#include <stdio.h>
#include <IOKit/hid/IOHIDLib.h>
#include <mach/mach_time.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <glob.h>
#include <copyfile.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/syslimits.h>

#include "osx_handmade.h"

// TODO(Kapsy): Global for now.
global_variable bool32 GlobalRunning;
global_variable bool32 GlobalPause;
global_variable bool32 GlobalLoop;
global_variable osx_offscreen_buffer GlobalBackBuffer;
global_variable osx_audio_buffer GlobalAudioBuffer;

global_variable uint64 AudioCallbackFlipTime;

// TODO: (Kapsy) Should be moving to osx_state, but we can't because we
// need a way of referring to it each time we open a file from the Game side.
global_variable char GlobalResourcesPath[OSX_STATE_FILE_NAME_COUNT];

// TODO: (Kapsy) Move to osx_state?
global_variable IOHIDManagerRef HIDManager;
global_variable osx_keyboard_message GlobalKeyboardMessages[256];
global_variable uint32 GlobalKeyboardMessagesCount = 0;

global_variable bool32 DEBUGGlobalShowCursor;

// TODO: (Kapsy) Rename to OSXName?
@class HHView;
@class HHAppDelegate;
@class HHWindowDelegate;

global_variable HHAppDelegate *AppDelegate;
global_variable NSWindow *Window;

@interface HHAppDelegate: NSObject<NSApplicationDelegate> { }
@property (nonatomic, strong) NSArray *XibObjects;
@end

@implementation HHAppDelegate
 -(NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *) Sender
{
    GlobalRunning = false;
    return NSTerminateCancel;
}
@end


@interface HHView: NSView
@end

@implementation HHView
 -(instancetype)initWithFrame:(NSRect) FrameRect
{
    self = [super initWithFrame: FrameRect];
    if (self) { }
    return self;
}

// TODO: (Kapsy) Should possibly black out the unused parts of the screen like
// Win32, but we would actually need to create a separate buffer which creates all sorts of problems.
// Going to leave this until actually required.
-(void)drawRect:(NSRect)dirtyRect
{
    CGContextRef Context = [[NSGraphicsContext currentContext] CGContext];
    CGImageRef ImageRef = CGBitmapContextCreateImage(GlobalBackBuffer.Context);
    CGContextDrawImage(Context, self.frame, ImageRef);
    CGImageRelease(ImageRef);
}

-(BOOL)acceptsFirstResponder
{
    return YES;
}

-(void)keyDown:(NSEvent *)theEvent
{
}

-(void)keyUp:(NSEvent *)theEvent
{
}

-(void)flagsChanged:(NSEvent *)theEvent
{
}

-(void)updateTrackingAreas
{
    [super updateTrackingAreas];

    NSTrackingArea *TrackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
        owner:self
        userInfo:nil];

    [self addTrackingArea:TrackingArea];
}

-(void)mouseEntered:(NSEvent *)theEvent
{
    [super mouseEntered:theEvent];

    if(DEBUGGlobalShowCursor)
    {
        // [[NSCursor crosshairCursor] push];
    }
    else
    {
        [NSCursor hide];
    }
}

-(void)mouseExited:(NSEvent *)theEvent
{
    [super mouseExited:theEvent];

    if(DEBUGGlobalShowCursor)
    {
        // [NSCursor pop];
    }
    else
    {
        [NSCursor unhide];
    }
}

@end

internal int
StringLength(char *String)
{
    int Count = 0;
    while(*String++)
    {
        ++Count;
    }
    return(Count);
}

internal void
CatStrings(size SourceACount, char *SourceA,
        size SourceBCount, char *SourceB,
        size DestCount, char *Dest)
{
    for(int Index = 0;
    Index < SourceACount;
    ++Index)
    {
        *Dest++ = *SourceA++;
    }

    for(int Index = 0;
    Index < SourceBCount;
    ++Index)
    {
        *Dest++ = *SourceB++;
    }

    *Dest = 0;
}

// NOTE: (Kapsy)
// AppPath: .../build/Handmade.app/Contents/MacOS/handmade
// AppPathOnePastLastSlash: handmade
internal void
OSXUpdateAppPath(osx_state *State)
{
    pid_t PID = getpid();
    int PIDPathSize = proc_pidpath(PID, &State->AppPath, sizeof(State->AppPath));
    if(PIDPathSize >= 0)
    {
        State->AppPathOnePastLastSlash = State->AppPath;

        for(char *Scan = State->AppPath;
                *Scan;
                ++Scan)
        {
            if(*Scan == '/')
            {
                State->AppPathOnePastLastSlash = Scan + 1;
            }
        }
    }
    else
    {
        // TODO: (Kapsy) Logging.
    }
}

// TODO: (Kapsy) This function requires a total refit!
internal void
OSXUpdateResourcesPath(osx_state *State)
{
    CFBundleRef MainBundle = CFBundleGetMainBundle();
    CFURLRef MainBundleURL = CFBundleCopyBundleURL(MainBundle);
    CFStringRef MainBundleURLString = CFURLGetString(MainBundleURL);

    char *MainBundleURLCString =
        (char *)CFStringGetCStringPtr(MainBundleURLString, kCFStringEncodingUTF8);
    char *ResourcesFolder = "Contents/Resources/";

    int FileURLPrefixLength = 7;
    MainBundleURLCString = MainBundleURLCString + FileURLPrefixLength;

    CatStrings(StringLength(MainBundleURLCString), MainBundleURLCString,
            StringLength(ResourcesFolder), ResourcesFolder, 0, GlobalResourcesPath);

    // TODO: (Kapsy) Cause EXC_BAD_ACCESS - required later on?
    // MainBundleURLCString = 0;
    // CFRelease(MainBundleURLString);
    // CFRelease(MainBundleURL);
    // CFRelease(MainBundle);
}

internal void
OSXBuildPathWithFilename(osx_state *State, char *Filename, int DestCount, char *Dest)
{
    CatStrings(State->AppPathOnePastLastSlash - State->AppPath, State->AppPath,
            StringLength(Filename), Filename,
            DestCount, Dest);
}

internal void
OSXResourcesPathWithFilename(char *Filename, int DestCount, char *Dest)
{
    CatStrings(StringLength(GlobalResourcesPath), GlobalResourcesPath,
            StringLength(Filename), Filename,
            DestCount, Dest);
}

DEBUG_PLATFORM_FREE_FILE_MEMORY(DEBUGPlatformFreeFileMemory)
{
    if(Memory)
    {
        // TODO: (Kapsy) Proper Error Handling.
        int32 Result = munmap(Memory, Size);

        Assert(Result == 0);
    }
}

DEBUG_PLATFORM_READ_ENTIRE_FILE(DEBUGPlatformReadEntireFile)
{
    debug_read_file_result Result = {};

    char FullPath[OSX_STATE_FILE_NAME_COUNT] = { 0 };
    OSXResourcesPathWithFilename(Filename, 0, FullPath);

    int FileHandle = open(FullPath, O_RDONLY,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
    if(FileHandle >= 0)
    {
        int SeekOffset = lseek(FileHandle, 0, SEEK_END);
        if(SeekOffset > 0)
        {
            lseek(FileHandle, 0, SEEK_SET);
            Result.ContentsSize = SeekOffset;
            Result.Contents = mmap(
                    Result.Contents,
                    Result.ContentsSize,
                    PROT_READ|PROT_WRITE,
                    MAP_PRIVATE|MAP_ANON,
                    -1, 0);

            ssize_t BytesRead = read(FileHandle, Result.Contents, Result.ContentsSize);
            if(BytesRead == -1)
            {
                // TODO: (Kapsy) Error handling/logging.
                // TODO: (Kapsy) Check the errno here.
            }
        }
    }

#if 0
    struct stat FileStat;
    stat(FullPath, &FileStat);
    FileSize = FileStat.st_size;
#endif
    return(Result);
}

DEBUG_PLATFORM_WRITE_ENTIRE_FILE(DEBUGPlatformWriteEntireFile)
{
    bool32 Result = false;

    char FullPath[OSX_STATE_FILE_NAME_COUNT] = { 0 };
    OSXResourcesPathWithFilename(Filename, 0, FullPath);

    int FileHandle =
        open(FullPath, O_WRONLY | O_CREAT | O_TRUNC,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);
    if(FileHandle >= 0)
    {
        ssize_t BytesWritten = write(FileHandle, Memory, Size);
        if(BytesWritten >= 0)
        {
            Result = true;
        }
        else
        {
            // TODO: (Kapsy) Check the errno here.
        }
    }

    return(Result);
}

time_t
OSXGetLastWriteTime(char *Filename)
{
    time_t LastWriteTime = 0;

    glob_t PGlob = {};
    int GlobResult = glob(Filename, 0, 0, &PGlob);
    if(GlobResult == 0 )
    {
        if(PGlob.gl_matchc > 0)
        {
            char *FirstInstanceOfFilename = PGlob.gl_pathv[0];
            int FileHandle = open(FirstInstanceOfFilename, O_RDONLY);
            if(FileHandle)
            {
                struct stat FileStat;
                if(fstat(FileHandle, &FileStat) == 0)
                {
                    LastWriteTime = FileStat.st_mtimespec.tv_sec;
                }
                close(FileHandle);
            }
        }
    }
    else
    {
        // TODO: (Kapsy) HandleGlob Result Errors.
    }
    return(LastWriteTime);
}

internal osx_game_code
OSXLoadGameCode(char *SourceDLName, char *TempDLName, char *LockFileName)
{
    osx_game_code Result = {};

    // NOTE: (Kapsy) Checks for the existence of a lock file, to prevent loading
    // until it is removed by the compilation process. See Ep 39.
    // May not be needed for Xcode debugging but leaving here until can
    // confirm that is the case.
    glob_t LockFilePGlob = {};
    int GlobResult = glob(LockFileName, GLOB_NOCHECK, 0, &LockFilePGlob);

    if(GlobResult == 0)
    {
        if(LockFilePGlob.gl_matchc == 0)
        {
            Result.LastDLWriteTime = OSXGetLastWriteTime(SourceDLName);

            copyfile_state_t CopyState = copyfile_state_alloc();
            int CopyResult = copyfile(SourceDLName, TempDLName, CopyState, COPYFILE_DATA | COPYFILE_XATTR);

            if(CopyResult == 0)
            {
                Result.GameCodeDL = dlopen(TempDLName, RTLD_LAZY|RTLD_GLOBAL);
                if(Result.GameCodeDL)
                {
                    Result.UpdateAndRender = (game_update_and_render *)
                        dlsym(Result.GameCodeDL, "GameUpdateAndRender");

                    Result.GetSoundSamples = (game_get_sound_samples *)
                        dlsym(Result.GameCodeDL, "GameGetSoundSamples");

                    Result.IsValid =
                        (Result.UpdateAndRender && Result.GetSoundSamples);
                }
            }
            else
            {
                // TODO: (Kapsy) Error Logging.
            }
            copyfile_state_free(CopyState);
        }
    }
    else
    {
        // TODO: (Kapsy) Error Logging.
    }

    if(!Result.IsValid)
    {
        Result.UpdateAndRender = 0;
        Result.GetSoundSamples = 0;
    }

    return(Result);
}

internal void
OSXUnloadGameCode(osx_game_code *GameCode)
{
    if(GameCode->GameCodeDL)
    {
        dlclose(GameCode->GameCodeDL);
        GameCode->GameCodeDL = 0;
    }

    GameCode->IsValid = false;
    GameCode->UpdateAndRender = 0;
    GameCode->GetSoundSamples = 0;
}

osx_window_dimension
OSXGetWindowDimension(NSWindow *Window)
{
    osx_window_dimension Result;

    HHView *View = (HHView *)[Window contentView];

    Result.Width = View.frame.size.width;
    Result.Height = View.frame.size.height;

    return Result;
}

internal void
OSXResize(osx_offscreen_buffer *Buffer, int Width, int Height)
{
    if(Buffer->Memory)
    {
        munmap(Buffer->Memory, 0);
    }

    uint32 DefaultWidth = 960;
    uint32 DefaultHeight = 540;

    if((Width >= DefaultWidth*2) &&
            (Height >= DefaultHeight*2))
    {
        Buffer->Width = DefaultWidth;
        Buffer->Height = DefaultHeight;
    }
    else
    {
        Buffer->Width = Width;
        Buffer->Height = Height;
    }

    int BytesPerPixel = 4;
    Buffer->BytesPerPixel = BytesPerPixel;
    Buffer->Pitch = BytesPerPixel*Buffer->Width;
    int BitmapMemorySize = (Buffer->Width*Buffer->Height)*BytesPerPixel;

    // NOTE(Kapsy): We can't use MAP_FIXED, as Buffer->Memory will be 0
    Buffer->Memory = mmap(Buffer->Memory, BitmapMemorySize,
            PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON,
            -1, 0);
    if(Buffer->Memory == MAP_FAILED)
    {
        // TODO: (Kapsy) Logging.
    }

    // TODO(Kapsy): Check if we can obtain the CGColorSpaceRef by calling CMGetSystemProfile.
    CGColorSpaceRef ColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    Buffer->Context =
        CGBitmapContextCreate(
                Buffer->Memory,
                Buffer->Width,
                Buffer->Height,
                8,
                Buffer->Pitch,
                ColorSpace,
                kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(ColorSpace);
}

// TODO: (Kapsy) Perhaps this write operation should be added to a Queue so that it only
// gets performed when is convenient for the Callback.
internal void
OSXFillAudioBuffer(game_sound_buffer *GameBuffer,
        osx_audio_buffer *OSXBuffer, uint32 Start, uint32 End)
{
    void *RegionRight =
        (void *)((uint8 *)OSXBuffer->StartCursor + Start);
    uint32 RegionRightSize = 0;

    void *RegionLeft = OSXBuffer->StartCursor;
    uint32 RegionLeftSize = 0;

    if(Start > End)
    {
        RegionRightSize = OSXBuffer->Size - Start;
        RegionLeftSize = End;
    }
    else
    {
        RegionRightSize = End - Start;
    }

    int16 *InSamples = GameBuffer->Samples;
    int16 *OutSamples = (int16 *)RegionRight;

    uint32 RegionRightFrameCount =
        RegionRightSize / OSXBuffer->BytesPerFrame;
    for(int FrameIndex = 0;
            FrameIndex < RegionRightFrameCount;
            ++FrameIndex)
    {
        *OutSamples++ = *InSamples++;
        *OutSamples++ = *InSamples++;
        OSXBuffer->RunningIndex += OSXBuffer->BytesPerFrame;
    }

    OutSamples = (int16 *)RegionLeft;

    uint32 RegionLeftFrameCount =
        RegionLeftSize / OSXBuffer->BytesPerFrame;
    for(int FrameIndex = 0;
            FrameIndex < RegionLeftFrameCount;
            ++FrameIndex)
    {
        *OutSamples++ = *InSamples++;
        *OutSamples++ = *InSamples++;
        OSXBuffer->RunningIndex += OSXBuffer->BytesPerFrame;
    }
}

// TODO: (Kapsy) Pass the Buffer as ClientData.
internal OSStatus
DefaultDeviceIOProc(AudioObjectID         Device,
                  const AudioTimeStamp*   Now,
                  const AudioBufferList*  InputData,
                  const AudioTimeStamp*   InputTime,
                  AudioBufferList*        OutputData,
                  const AudioTimeStamp*   OutputTime,
                  void* __nullable        ClientData)
{
    OSStatus Error = noErr;

    // NOTE: (Kapsy) Test tone.
#if 0
    real32 *FloatBuffer = (real32 *)OutputData->mBuffers[0].mData;

    local_persist real32 TSine = 0;
    real32 ToneHzSamples = GlobalAudioBuffer.FrameRate/440;

    for( int FrameIndex = 0;
            FrameIndex < 512;
            ++FrameIndex)
    {
        real32 SineValue = sinf(TSine);
        real32 SampleValue = SineValue;

        *FloatBuffer++ = SampleValue;
        *FloatBuffer++ = SampleValue;

        TSine += 2.0f*Pi32*1.0f/ToneHzSamples;
    }

    return(noErr);
#endif

    mach_timebase_info_data_t MachTimebaseInfo;
    mach_timebase_info(&MachTimebaseInfo);

    AudioCallbackFlipTime = mach_absolute_time();
    // TODO: (Kapsy) See if there is a way we can access the
    // _actual_ time the audio comes out of the speakers.
    // Want to see how the timestamps returned here compare with the
    // real timestamps.
    uint64 CallbackAudioCallbackFlipTime = Now->mHostTime;

#if 0
    uint64 FlipTimeDifference =
        CallbackAudioCallbackFlipTime - AudioCallbackFlipTime;
    uint32 FlipTimeDifferenceFrames =
        (uint32)
        ((real32)SFromNS((CallbackAudioCallbackFlipTime - AudioCallbackFlipTime) *
            (MachTimebaseInfo.numer/MachTimebaseInfo.denom)) *
         (real32)GlobalAudioBuffer.FrameRate);
    NSLog(@"FlipTimeDifferenceFrames:%d", FlipTimeDifferenceFrames);
#endif

    // NOTE: (Kapsy) Game requires Interleaved, 16 bit int.
    real32 *OutBuffer = (real32 *)OutputData->mBuffers[0].mData;
    int16 *InBuffer = (int16 *)GlobalAudioBuffer.ReadCursor;
    uint32 NumberFrames = GlobalAudioBuffer.HardwareChunkSizeFrames;

    int16 Int16Max = 0x7fff;
    // int16 Int16Min = 0x8000;

    for(int FrameIndex = 0;
            FrameIndex < NumberFrames;
            ++FrameIndex)
    {
        *OutBuffer++ = ((real32)(*InBuffer++)/(real32)Int16Max);
        *OutBuffer++ = ((real32)(*InBuffer++)/(real32)Int16Max);
    }

    // TODO: Perform any Queued buffer write operations here.
    GlobalAudioBuffer.ReadIndex += NumberFrames * GlobalAudioBuffer.BytesPerFrame;
    GlobalAudioBuffer.WriteIndex += NumberFrames * GlobalAudioBuffer.BytesPerFrame;

    // TODO: (Kapsy) Implement a H/W Play Cursor which indicates where
    // sound is actually being produced by the speaker.

    // TODO: (Kapsy) Make Buffer Cursors all (uint8 *)s?
    GlobalAudioBuffer.ReadCursor =
        (void *)
        (((uint8 *)GlobalAudioBuffer.StartCursor) +
         (GlobalAudioBuffer.ReadIndex % GlobalAudioBuffer.Size));

    GlobalAudioBuffer.WriteCursor =
        (void *)
        (((uint8 *)GlobalAudioBuffer.StartCursor) +
         (GlobalAudioBuffer.WriteIndex % GlobalAudioBuffer.Size));

    return(noErr);
}




// TODO: (Kapsy)
// extern OSStatus AudioObjectAddPropertyListener - will probably be
// required for some properties, not sure which yet at this stage -
// kAudioDevicePropertyBufferFrameSize would be a good one to watch.

// TODO: (Kapsy) kAudioDevicePropertyActualSampleRate - Not exactly sure,
// but maybe this would be useful for taking into account jitter?
internal void
OSXGetAudioHardwareProperties(osx_audio_buffer *Buffer)
{
    AudioObjectPropertyAddress DefaultOutputDeviceAddress = {};
    DefaultOutputDeviceAddress.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
    DefaultOutputDeviceAddress.mScope = kAudioObjectPropertyScopeGlobal;
    DefaultOutputDeviceAddress.mElement = kAudioObjectPropertyElementMaster;

    AudioObjectID DefaultOutputDevice = 0;
    UInt32 DefaultOutputDeviceSize = sizeof(DefaultOutputDevice);

    OSStatus Error = noErr;
    Error = AudioObjectGetPropertyData(kAudioObjectSystemObject,
            &DefaultOutputDeviceAddress,
            0, 0,
            &DefaultOutputDeviceSize,
            &DefaultOutputDevice);

    if(Error == noErr)
    {
        AudioObjectPropertyAddress NominalSampleRateAddress = {};
        NominalSampleRateAddress.mSelector = kAudioDevicePropertyNominalSampleRate;
        NominalSampleRateAddress.mScope = kAudioObjectPropertyScopeGlobal;
        NominalSampleRateAddress.mElement = kAudioObjectPropertyElementMaster;

        Float64 NominalSampleRate = 0.0;
        UInt32 NominalSampleRateSize = sizeof(NominalSampleRate);

        Error = AudioObjectGetPropertyData(DefaultOutputDevice,
                &NominalSampleRateAddress,
                0, 0,
                &NominalSampleRateSize,
                &NominalSampleRate);

        if(Error == noErr)
        {
            AudioObjectPropertyAddress BufferFrameSizeAddress = {};
            BufferFrameSizeAddress.mSelector = kAudioDevicePropertyBufferFrameSize;
            BufferFrameSizeAddress.mScope = kAudioObjectPropertyScopeGlobal;
            BufferFrameSizeAddress.mElement = kAudioObjectPropertyElementMaster;

            UInt32 BufferFrameSize = 0;
            UInt32 BufferFrameSizeSize = sizeof(BufferFrameSize);

            Error = AudioObjectGetPropertyData(DefaultOutputDevice,
                    &BufferFrameSizeAddress,
                    0, 0,
                    &BufferFrameSizeSize,
                    &BufferFrameSize);


            if(Error == noErr)
            {
                AudioObjectPropertyAddress StreamConfigurationAddress = {};
                StreamConfigurationAddress.mSelector = kAudioDevicePropertyStreamConfiguration;
                StreamConfigurationAddress.mScope = kAudioObjectPropertyScopeOutput;
                StreamConfigurationAddress.mElement = kAudioObjectPropertyElementMaster;

                UInt32 StreamConfigurationSize = 0;
                Error = AudioObjectGetPropertyDataSize(DefaultOutputDevice,
                        &StreamConfigurationAddress,
                        0, 0,
                        &StreamConfigurationSize);


                if(Error == noErr)
                {

                    // TODO: (Kapsy) Shouldn't be calloc'ing here.
                    AudioBufferList *StreamConfiguration =
                        (AudioBufferList *)calloc(StreamConfigurationSize, 1);

                    Error = AudioObjectGetPropertyData(DefaultOutputDevice,
                            &StreamConfigurationAddress,
                            0, 0,
                            &StreamConfigurationSize,
                            StreamConfiguration);

                    if(Error == noErr)
                    {
                        // TODO: (Kapsy) Test with different Audio H/W.
                        Assert(StreamConfiguration->mNumberBuffers == 1)

                        // TODO: (Kapsy) Should really be looking at these two properties too:
                        // kAudioDevicePropertyBufferFrameSizeRange
                        // kAudioDevicePropertyUsesVariableBufferFrameSizes
                        // Just so we can ensure it's not going to change -
                        // if it can we need to be able to handle.

                        // TODO: (Kapsy) Need to ensure that our Stream Data Type is actually 8 bytes
                        // per frame.

                        // NOTE: (Kapsy) From AudioHardware.h:
                        // If the format is a linear PCM format, the data will
                        // always be presented as 32 bit, native endian floating
                        // point. All conversions to and from the true physical
                        // format of the hardware is handled by the device's driver.
                        Assert((BufferFrameSize * 8) == StreamConfiguration->mBuffers[0].mDataByteSize);
                        Buffer->DefaultOutputDevice = DefaultOutputDevice;

                        Buffer->HardwareChunkSizeFrames = BufferFrameSize;
                        // TODO: (Kapsy) This is the _native_ H/W chunk size,
                        // seems we don't really need it, so might be easier
                        // to remove altogether.
                        // Buffer->HardwareChunkSize = BufferFrameSize * 8;
                        Buffer->FrameRate = NominalSampleRate;
                        // TODO: (Kapsy) Way to query the H/W directly for the channel count?
                        Buffer->ChannelCount = StreamConfiguration->mBuffers[0].mNumberChannels;
                    }
                    else
                    {
                        Assert(0);
                        // TODO: (Kapsy) Logging.
                    }
                }
                else
                {
                    // TODO: (Kapsy) Logging.
                }
            }
            else
            {
                // TODO: (Kapsy) Logging.
            }
        }
        else
        {
            // TODO: (Kapsy) Logging.
        }
    }
    else
    {
        // TODO: (Kapsy) Logging.
    }
}

internal void
OSXStartAudioHardware(osx_audio_buffer *Buffer)
{
    Assert(Buffer->DefaultOutputDevice);

    OSStatus Error = noErr;

    // TODO: (Kapsy) Pass the buffer through here?
    // Or should we just access it globally?
    AudioDeviceIOProcID IOProcID = 0;
    Error = AudioDeviceCreateIOProcID(Buffer->DefaultOutputDevice,
            &DefaultDeviceIOProc,
            0,
            &IOProcID);

    if(Error == noErr)
    {
        Error = AudioDeviceStart(Buffer->DefaultOutputDevice, IOProcID);
        if(Error == noErr)
        {
            NSLog(@"DefaultOutputDevice Started!");
        }
        else
        {
            // TODO: (Kapsy) Logging.
        }
    }
}

internal void
OSXGetInputFilePath(osx_state *State, bool32 InputStream,
        int SlotIndex, int DestCount, char *Dest)
{
    char Temp[64];
    sprintf(Temp, "loop_edit_%d_%s.hmi", SlotIndex, InputStream ? "input" : "state");
    OSXBuildPathWithFilename(State, Temp, DestCount, Dest);
}

internal osx_replay_buffer *
OSXGetReplayBuffer(osx_state *State, int unsigned Index)
{
    Assert(Index > 0);
    Assert(Index < ArrayCount(State->ReplayBuffers));
    osx_replay_buffer *Result = &State->ReplayBuffers[Index];
    return(Result);
}

internal void
OSXBeginRecordingInput(osx_state *State, int InputRecordingIndex)
{
    osx_replay_buffer *ReplayBuffer = OSXGetReplayBuffer(State, InputRecordingIndex);
    if(ReplayBuffer->MemoryBlock)
    {
        State->InputRecordingIndex = InputRecordingIndex;

        char Filename[OSX_STATE_FILE_NAME_COUNT];
        OSXGetInputFilePath(State, true, InputRecordingIndex, sizeof(Filename), Filename);

        State->RecordingHandle =
            open(Filename, O_WRONLY | O_CREAT | O_TRUNC,
                S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);

        memcpy(ReplayBuffer->MemoryBlock, State->GameMemoryBlock, State->TotalSize);
    }
}

internal void
OSXEndRecordingInput(osx_state *State)
{
    close(State->RecordingHandle);
    State->InputRecordingIndex = 0;
}

internal void
OSXBeginInputPlayback(osx_state *State, int InputPlayingIndex)
{
    osx_replay_buffer *ReplayBuffer = OSXGetReplayBuffer(State, InputPlayingIndex);
    if(ReplayBuffer->MemoryBlock)
    {
        State->InputPlayingIndex = InputPlayingIndex;

        char Filename[OSX_STATE_FILE_NAME_COUNT];
        OSXGetInputFilePath(State, true, InputPlayingIndex, sizeof(Filename), Filename);

        State->PlaybackHandle = open(Filename, O_RDONLY, 0);

        memcpy(State->GameMemoryBlock, ReplayBuffer->MemoryBlock, State->TotalSize);
    }
}

internal void
OSXEndInputPlayback(osx_state *State)
{
    close(State->PlaybackHandle);
    State->InputPlayingIndex = 0;
}

internal void
OSXRecordInput(osx_state *State, game_input *NewInput)
{
    uint32 BytesWritten =
        write(State->RecordingHandle, NewInput, sizeof(*NewInput));
}

internal void
OSXPlaybackInput(osx_state *State, game_input *NewInput)
{
    size_t BytesRead = read(State->PlaybackHandle, NewInput, sizeof(*NewInput));

    if(BytesRead == 0)
    {
        int PlayingIndex = State->InputPlayingIndex;
        OSXEndInputPlayback(State);
        OSXBeginInputPlayback(State, PlayingIndex);
        BytesRead = read(State->PlaybackHandle, NewInput, sizeof(*NewInput));
    }
}

@interface HHWindowDelegate: NSObject<NSWindowDelegate> { }
@end

@implementation HHWindowDelegate

-(BOOL)windowShouldClose:(id)sender
{
    GlobalRunning = false;
    return NO;
}

// NOTE: (Kapsy) Stops the render loop will need to implement if we want
// to conitinue animating while dragging.
-(void)windowDidResize:(id)sender
{
    // NOTE: (Kapsy) Appears that the way we're doing this is legitimate:
    // http://www.cocoabuilder.com/archive/cocoa/135042-function-to-write-to-one-pixel.html

    osx_window_dimension Dimension = OSXGetWindowDimension(Window);
    // // printf("windowDidResize: w:%d h:%d\n", Dimension.Width, Dimension.Height);
    OSXResize(&GlobalBackBuffer, Dimension.Width, Dimension.Height);

    // TODO: (Kapsy) Need to re-implement this.
    // GameUpdateAndRender(&Buffer, XOffset, YOffset);
}

@end

internal void
OSXInitNSApplication(void)
{
    NSApplication *Application = [NSApplication sharedApplication];
    AppDelegate = [[HHAppDelegate alloc] init];
    [Application setDelegate: AppDelegate];

    const char *ResourcePath = [[[NSBundle mainBundle] resourcePath] UTF8String];
    chdir(ResourcePath);

    [Application finishLaunching];
}

internal void
OSXProcessKeyboardMessage(game_button_state *NewState, bool32 IsDown)
{
    if(NewState->EndedDown != IsDown)
    {
        NewState->EndedDown = IsDown;
        ++NewState->HalfTransitionCount;
    }
}


// TODO: (Kapsy) Need to add kHIDUsage_GD_Keypad Generic Desktop Page to the
// same Callback to handle modifier keys etc.

/*
  IMPORTANT: (Kapsy) Does not take into account OSX mappings!
  Run:

  defaults -currentHost read -g
  ioreg -n IOHIDKeyboard -r

  To see a list of mappings.

  Appears that NSEvents are returned with the correct mappings.
  We can get the Manufacturer etc for existing KB, and Defaults, in IOHIDParameter.h:
  #define kIOHIDKeyboardModifierMappingPairsKey   "HIDKeyboardModifierMappingPairs"
  #define kIOHIDKeyboardModifierMappingSrcKey     "HIDKeyboardModifierMappingSrc"
  #define kIOHIDKeyboardModifierMappingDstKey     "HIDKeyboardModifierMappingDst"

  Mapping constants can be found here:
  /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.11.sdk/System/Library/Frameworks/IOKit.framework/Versions/A/Headers/hidsystem/ev_keymap.h

  For example:
  [> support for right hand modifier <]
  #define NX_MODIFIERKEY_RSHIFT		9
  #define NX_MODIFIERKEY_RCONTROL		10
  #define NX_MODIFIERKEY_RALTERNATE	11
  #define NX_MODIFIERKEY_RCOMMAND		12

  Also need to allow for mappings changing mid App.
  Another option would just be to allow re-binding and let the user deal with it.
  Would like to use IOKit if possible. NSEvents probably just use IOKit underneath?

  We _should_ be able to obtain the mappings by calling:
  CFArrayRef KeyboardModifierMappingPairs =
      (CFArrayRef)IOHIDDeviceGetProperty(Device, CFSTR(kIOHIDKeyboardModifierMappingPairsKey));
  But I can't seem to get that working just yet.

  The same would apply for mouse settings.
 */

internal void
OSXHIDKeyboardValueCallback(void *Context,
        IOReturn Result,
        void *Sender,
        IOHIDValueRef Value)
{
    if([Window isKeyWindow])
    {
        IOHIDElementRef Element = IOHIDValueGetElement(Value);
        if(CFGetTypeID(Element) == IOHIDElementGetTypeID())
        {
            UInt32 Usage = (UInt32)IOHIDElementGetUsage(Element);
            UInt32 IntegerValue = (UInt32)IOHIDValueGetIntegerValue(Value);

#if 0
            // NOTE: (Kapsy) IOHIDDeviceSetInputValueMatching doesn't work as expected,
            // so filtering manually for logging.
            if(Usage >= kHIDUsage_KeyboardA &&
                    Usage <= kHIDUsage_KeyboardRightGUI)
            {
                NSLog(@"Usage: %d", (unsigned int)Usage);
                NSLog(@"IntegerValue: %d", (unsigned int)IntegerValue);
            }
#endif

            // TODO: (Kapsy) This is NOT thread safe! Need a better solution here.
            osx_keyboard_message *Message = &GlobalKeyboardMessages[GlobalKeyboardMessagesCount++];
            Message->Usage = Usage;
            Message->IntegerValue = IntegerValue;
        }
    }
}

// kHIDUsage_GD_X    = 0x30,    [> Dynamic Value <]
// kHIDUsage_GD_Y    = 0x31,    [> Dynamic Value <]
// kHIDUsage_GD_Wheel    = 0x38,    [> Dynamic Value <]

// TODO: (Kapsy) because our game can run in a Window,
// then we need to get the pointer relative to the Desktop.
// I could only imagine tapping into the raw HID would be useful for a fullscreen
// application, where we need to control the mouse position based on the sensitivity,
// accelaration etc. May be wrong about this.
internal void
OSXHIDMouseValueCallback(void *Context,
        IOReturn Result,
        void *Sender,
        IOHIDValueRef Value)
{
    if([Window isKeyWindow])
    {
        IOHIDElementRef Element = IOHIDValueGetElement(Value);

        if(CFGetTypeID(Element) == IOHIDElementGetTypeID())
        {
            UInt32 Usage = (UInt32)IOHIDElementGetUsage(Element);
            UInt32 IntegerValue = (UInt32)IOHIDValueGetIntegerValue(Value);

            double_t ScaledValueCalibrated = IOHIDValueGetScaledValue(Value, kIOHIDValueScaleTypeCalibrated);
            double_t ScaledValuePhysical = IOHIDValueGetScaledValue(Value, kIOHIDValueScaleTypePhysical);

                NSLog(@"Usage: %d", (unsigned int)Usage);
                NSLog(@"IntegerValue: %d", (unsigned int)IntegerValue);
                NSLog(@"ScaledValueCalibrated: %f", ScaledValueCalibrated);
                NSLog(@"ScaledValuePhysical: %f", ScaledValuePhysical);

            switch(Usage)
            {
            }
        }

    }
}

// TODO: (Kapsy) Signal to Game what Devices we have available.
internal void
OSXHIDMatchingCallback(void *Context,
        IOReturn Result,
        void *Sender,
        IOHIDDeviceRef Device)
{
    // TODO: (Kapsy) To be used when implementing Game Pad support.
    CFStringRef ManufacturerRef =
        (CFStringRef)IOHIDDeviceGetProperty(Device, CFSTR(kIOHIDManufacturerKey));

    CFStringRef VendorIDRef =
        (CFStringRef)IOHIDDeviceGetProperty(Device, CFSTR(kIOHIDVendorIDKey));

    CFStringRef ProductIDRef =
        (CFStringRef)IOHIDDeviceGetProperty(Device, CFSTR(kIOHIDProductIDKey));

    CFNumberRef UsagePageRef =
        (CFNumberRef)IOHIDDeviceGetProperty(Device, CFSTR(kIOHIDPrimaryUsagePageKey));

    CFNumberRef UsageRef =
        (CFNumberRef)IOHIDDeviceGetProperty(Device, CFSTR(kIOHIDPrimaryUsageKey));

    UInt32 UsagePage = 0;
    CFNumberGetValue(UsagePageRef, kCFNumberIntType, &UsagePage);
    CFRelease(UsagePageRef);

    UInt32 Usage = 0;
    CFNumberGetValue(UsageRef, kCFNumberIntType, &Usage);
    CFRelease(UsageRef);

    if(UsagePage == kHIDPage_GenericDesktop && Usage == kHIDUsage_GD_Keypad)
    {
        NSLog(@"Keypad input device found.");
    }

// #define kIOHIDKeyboardModifierMappingPairsKey   "HIDKeyboardModifierMappingPairs"
// #define kIOHIDKeyboardModifierMappingSrcKey     "HIDKeyboardModifierMappingSrc"
// #define kIOHIDKeyboardModifierMappingDstKey     "HIDKeyboardModifierMappingDst"

    // TODO: (Kapsy) Add support for XBox360 Controller/Gamepad.
    if(UsagePage == kHIDPage_GenericDesktop && Usage == kHIDUsage_GD_Keyboard)
    {
        NSLog(@"Keyboard input device found.");

        // NOTE: (Kapsy) Going to leave for now as these do not work, but I'm _sure_
        // there's a way to find them.

        // CFArrayRef KeyboardModifierMappingPairs =
        //     (CFArrayRef)IOHIDDeviceGetProperty(Device, CFSTR(kIOHIDKeyboardModifierMappingPairsKey));

        // CFNumberRef KeyMappingRef =
        //     (CFNumberRef)IOHIDDeviceGetProperty(Device, CFSTR(kIOHIDKeyMappingKey));


// TODO: (Kapsy) For some reason this cancels modifier keys too.
// Will attempt again if I can find some better documentation for
// IOHIDDeviceSetInputValueMatching
#if 0
        CFMutableDictionaryRef ElementUsage = nil;
        int MinUsage = 0x04;
        CFNumberRef MinUsageRef =
            CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &MinUsage);
        if(MinUsageRef)
        {
            int MaxUsage = 0xE7;
            CFNumberRef MaxUsageRef =
                CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &MaxUsage);
            if(MaxUsageRef)
            {
                ElementUsage = CFDictionaryCreateMutable(
                        kCFAllocatorDefault,
                        0,
                        &kCFTypeDictionaryKeyCallBacks,
                        &kCFTypeDictionaryValueCallBacks);

                if(ElementUsage)
                {
                    CFDictionarySetValue(ElementUsage, CFSTR(kIOHIDElementUsageMinKey), MinUsageRef);
                    CFDictionarySetValue(ElementUsage, CFSTR(kIOHIDElementUsageMaxKey), MaxUsageRef);
                    IOHIDDeviceSetInputValueMatching(Device, ElementUsage);
                }
                else
                {
                    // TODO: (Kapsy) Logging.
                }
            }
            else
            {
                // TODO: (Kapsy) Logging.
            }
        }
        else
        {
            // TODO: (Kapsy) Logging.
        }
#endif
        if(IOHIDDeviceOpen(Device, kIOHIDOptionsTypeNone) == kIOReturnSuccess)
        {
            IOHIDDeviceRegisterInputValueCallback(Device, OSXHIDKeyboardValueCallback, nil);
        }
    }

#if 0
    else if(UsagePage == kHIDPage_GenericDesktop && Usage == kHIDUsage_GD_Mouse)
    {
        NSLog(@"Mouse input device found.");
        if(IOHIDDeviceOpen(Device, kIOHIDOptionsTypeNone) == kIOReturnSuccess)
        {
            IOHIDDeviceRegisterInputValueCallback(Device, OSXHIDMouseValueCallback, nil);
        }
    }
#endif

}

internal CFMutableDictionaryRef
OSXHIDDeviceDictionary(UInt32 UsagePage, UInt32 Usage)
{
    CFMutableDictionaryRef Result = nil;

    // TODO: (Kapsy) Are these checks really necessary?
    // I suppose the allocation _could_ fail.
    CFNumberRef UsagePageRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &UsagePage);
    if(UsagePageRef)
    {
        CFNumberRef UsageRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &Usage);
        if(UsageRef)
        {

            Result = CFDictionaryCreateMutable(
                    kCFAllocatorDefault,
                    0,
                    &kCFTypeDictionaryKeyCallBacks,
                    &kCFTypeDictionaryValueCallBacks);

            if(Result)
            {
                CFDictionarySetValue(Result, CFSTR(kIOHIDDeviceUsagePageKey), UsagePageRef);
                CFDictionarySetValue(Result, CFSTR(kIOHIDDeviceUsageKey), UsageRef);
            }
            else
            {
                // TODO: (Kapsy) Logging.
            }
        }
        else
        {
            // TODO: (Kapsy) Logging.
        }
    }
    else
    {
        // TODO: (Kapsy) Logging.
    }
    return Result;
}

inline real32
MachTimeElapsedNS(uint64 StartMachTime, mach_timebase_info_data_t MachTimebaseInfo)
{
    real32 ResultNS = 0;

    uint64 EndMachTime = mach_absolute_time();
    ResultNS =
        (EndMachTime - StartMachTime) *
        (MachTimebaseInfo.numer/MachTimebaseInfo.denom);

    return(ResultNS);
}

internal void
OSXProcessPendingKeyboardMessages(osx_state *State, game_controller_input *KeyboardController)
{
    for(int Index = 0;
            Index < GlobalKeyboardMessagesCount;
            ++Index)
    {
        osx_keyboard_message Message = GlobalKeyboardMessages[Index];
        bool32 IsDown = (bool32)Message.IntegerValue;

        switch(Message.Usage)
        {
            case kHIDUsage_KeyboardW:
                {
                    OSXProcessKeyboardMessage(&KeyboardController->MoveUp, IsDown);
                } break;

            case kHIDUsage_KeyboardA:
                {
                    OSXProcessKeyboardMessage(&KeyboardController->MoveLeft, IsDown);
                } break;

            case kHIDUsage_KeyboardS:
                {
                    OSXProcessKeyboardMessage(&KeyboardController->MoveDown, IsDown);
                } break;

            case kHIDUsage_KeyboardD:
                {
                    OSXProcessKeyboardMessage(&KeyboardController->MoveRight, IsDown);
                } break;

            case kHIDUsage_KeyboardQ:
                {
                    OSXProcessKeyboardMessage(&KeyboardController->LeftShoulder, IsDown);
                } break;

            case kHIDUsage_KeyboardE:
                {
                    OSXProcessKeyboardMessage(&KeyboardController->RightShoulder, IsDown);
                } break;

            case kHIDUsage_KeyboardEscape:
                {
                } break;

            case kHIDUsage_KeyboardSpacebar:
                {
                    OSXProcessKeyboardMessage(&KeyboardController->Start, IsDown);
                } break;

            case kHIDUsage_KeyboardRightArrow:
                {
                    OSXProcessKeyboardMessage(&KeyboardController->ActionRight, IsDown);
                } break;

            case kHIDUsage_KeyboardLeftArrow:
                {
                    OSXProcessKeyboardMessage(&KeyboardController->ActionLeft, IsDown);
                } break;

            case kHIDUsage_KeyboardDownArrow:
                {
                    OSXProcessKeyboardMessage(&KeyboardController->ActionDown, IsDown);
                } break;

            case kHIDUsage_KeyboardUpArrow:
                {
                    OSXProcessKeyboardMessage(&KeyboardController->ActionUp, IsDown);
                } break;

            case kHIDUsage_KeyboardP:
                {
                    GlobalPause = !GlobalPause;
                } break;

            case kHIDUsage_KeyboardL:
                {
                    // TODO: (Kapsy) Fix this, should be a better way.
                    if(Message.IntegerValue)
                    {
                        GlobalLoop = true;
                    }

                } break;

            case kHIDUsage_KeyboardLeftGUI:
            case kHIDUsage_KeyboardRightGUI:
                { } break;
        }
    }

    GlobalKeyboardMessagesCount = 0;
}
#if 1
internal void
OSXDebugDrawVertical(osx_offscreen_buffer *GlobalBackBuffer,
        int X, int Top, int Bottom, uint32 Color)
{
    if(Top <= 0)
    {
        Top = 0;
    }

    if(Bottom > GlobalBackBuffer->Height)
    {
        Bottom = GlobalBackBuffer->Height;
    }

    if((X >= 0) && (X < GlobalBackBuffer->Width))
    {
        uint8 *Pixel = ((uint8 *)GlobalBackBuffer->Memory +
                X*GlobalBackBuffer->BytesPerPixel +
                Top*GlobalBackBuffer->Pitch);
        for(int Y = Top;
                Y < Bottom;
                ++Y)
        {
            *(uint32 *)Pixel = Color;
            Pixel += GlobalBackBuffer->Pitch;
        }
    }
}

inline void
OSXDrawAudioBufferMarker(osx_offscreen_buffer *BackBuffer,
        osx_audio_buffer *AudioBuffer,
        real32 C, int PadX, int Top, int Bottom,
        int32 Value, uint32 Color)
{
    Assert(Value < AudioBuffer->Size);
    real32 XReal32 = (C * (real32)Value);
    int X = PadX + (int)XReal32;
    OSXDebugDrawVertical(BackBuffer, X, Top, Bottom, Color);
}

internal void
OSXDebugSyncDisplay(osx_offscreen_buffer *BackBuffer,
        int MarkerCount, osx_debug_time_marker *Markers,
        int CurrentMarkerIndex,
        osx_audio_buffer *AudioBuffer, real32 TargetSecondsPerFrame)
{
    // TODO: (Kapsy) Draw where we're writing out sound.
    int PadX = 16;
    int PadY = 16;
    int LineHeight = 64;

    int Top = PadY;
    int Bottom = PadY + LineHeight;

    real32 C = (real32)(BackBuffer->Width - 2*PadX) / (real32)AudioBuffer->Size;

    for(int MarkerIndex = 0;
    MarkerIndex < MarkerCount;
    ++MarkerIndex)
    {
        osx_debug_time_marker  *ThisMarker = &Markers[MarkerIndex];

        Assert(ThisMarker->ReadCursorAbsolute < AudioBuffer->Size);
        Assert(ThisMarker->WriteStart < AudioBuffer->Size);
        Assert(ThisMarker->WriteEnd < AudioBuffer->Size);

        uint32 ReadCursorAbsoluteColor = 0x00000000;
        uint32 ReadCursorColor = 0x000000FF;
        uint32 WriteCursorColor = 0x0000FF00;
        uint32 WriteStartColor = 0xFFFFFFFF;
        uint32 WriteEndColor = 0x00FF0000;

        // NSLog(@"I:%d RC: %d", MarkerIndex, ThisMarker->ReadCursor);

        OSXDrawAudioBufferMarker(
                BackBuffer,
                AudioBuffer,
                C,
                PadX,
                Top,
                Bottom,
                ThisMarker->ReadCursorAbsolute,
                ReadCursorAbsoluteColor);

        OSXDrawAudioBufferMarker(
                BackBuffer,
                AudioBuffer,
                C,
                PadX,
                Top + LineHeight,
                Bottom + LineHeight,
                ThisMarker->WriteEnd,
                WriteEndColor);

        OSXDrawAudioBufferMarker(
                BackBuffer,
                AudioBuffer,
                C,
                PadX,
                Top,
                Bottom,
                ThisMarker->WriteStart,
                WriteStartColor);

        if(MarkerIndex == CurrentMarkerIndex)
        {
            OSXDrawAudioBufferMarker(
                    BackBuffer,
                    AudioBuffer,
                    C,
                    PadX,
                    Top,
                    Bottom,
                    ThisMarker->ReadCursor,
                    ReadCursorColor);

            OSXDrawAudioBufferMarker(
                    BackBuffer,
                    AudioBuffer,
                    C,
                    PadX,
                    Top,
                    Bottom,
                    ThisMarker->WriteCursor,
                    WriteCursorColor);
        }
    }
}

#endif


internal real64
OSXDisplayRefreshRate(void)
{
    real64 Result = 0.0;
    uint32 DisplayCount = 0;
    uint32 MaxDisplays = 32;

    CGDirectDisplayID Displays[MaxDisplays];

    CGGetActiveDisplayList(MaxDisplays, Displays, &DisplayCount);

    // TODO: (Kapsy) Figure out which monitor our Window is actually showing in.
    for(int DisplayIndex = 0;
            DisplayIndex < DisplayCount;
            ++DisplayIndex)
    {
        CGDirectDisplayID Display = Displays[DisplayIndex];
        CGDisplayModeRef DisplayMode = CGDisplayCopyDisplayMode(Display);

        if(DisplayMode)
        {
            Result = CGDisplayModeGetRefreshRate(DisplayMode);
        }
    }
    return(Result);
}

int
main(int argc, const char * argv[])
{
    OSXInitNSApplication();

    osx_state OSXState = {};
    OSXUpdateAppPath(&OSXState);
    OSXUpdateResourcesPath(&OSXState);

    char SourceGameCodeDLFullPath[OSX_STATE_FILE_NAME_COUNT];
    OSXBuildPathWithFilename(&OSXState, "handmade.dylib",
            sizeof(SourceGameCodeDLFullPath), SourceGameCodeDLFullPath);
    char TempGameCodeDLFullPath[OSX_STATE_FILE_NAME_COUNT];

    // NOTE: (Kapsy) Would be build/Handmade.app/Contents/MacOS/handmade_temp.dylib
    OSXBuildPathWithFilename(&OSXState, "handmade_temp.dylib",
            sizeof(TempGameCodeDLFullPath), TempGameCodeDLFullPath);

    // NOTE: (Kapsy) Maybe not needed for OSX, but adding because it's easier
    // to do so now (EP39) than to try and backtrack and add later.
    char GameCodeLockFullPath[OSX_STATE_FILE_NAME_COUNT];
    OSXBuildPathWithFilename(&OSXState, "lock.tmp",
            sizeof(GameCodeLockFullPath), GameCodeLockFullPath);

    NSString *ToggleFullScreenTitle = @"Toggle Full Screen";
    NSMenuItem *ToggleFullScreenItem =
    [[NSMenuItem alloc] initWithTitle:ToggleFullScreenTitle
                               action:@selector(toggleFullScreen:)
                        keyEquivalent:@"f"];
    ToggleFullScreenItem.keyEquivalentModifierMask = NSControlKeyMask | NSCommandKeyMask;

    NSString *QuitTitle = @"Quit";
    NSMenuItem *QuitItem =
    [[NSMenuItem alloc] initWithTitle:QuitTitle
                               action:@selector(terminate:)
                        keyEquivalent:@"q"];

    NSMenu *AppMenu = [[NSMenu alloc] init];
    [AppMenu addItem:ToggleFullScreenItem];
    [AppMenu addItem:QuitItem];

    NSMenuItem *MenuItem = [[NSMenuItem alloc] init];
    [MenuItem setSubmenu:AppMenu];

    NSMenu *MenuBar = [[NSMenu alloc] init];
    [MenuBar addItem:MenuItem];

    [NSApp setMainMenu:MenuBar];

#if HANDMADE_INTERNAL
    DEBUGGlobalShowCursor = true;
#endif

    /* NOTE: (Kapsy) 1080p display mode is 1920x1080 -> Half of that is 960x540
       1920 -> 2048 = 2048-1920 -> 128 pixels
       1080 -> 2048 = 2048-1080 -> pixels 968
       1024 + 128 = 1152
     */
    NSRect Frame = NSMakeRect(0, 0, 960, 540);
    HHView *View = [[HHView alloc] initWithFrame: Frame];
    HHWindowDelegate *WinDelegate = [[HHWindowDelegate alloc] init];
    NSUInteger StyleMask =
        NSTitledWindowMask|NSResizableWindowMask|
        NSClosableWindowMask|NSMiniaturizableWindowMask;
    Window = [[NSWindow alloc] initWithContentRect: Frame
                                         styleMask: StyleMask
                                           backing: NSBackingStoreBuffered
                                             defer: NO];
    [Window setContentView: View];
    [Window setDelegate: WinDelegate];
    [Window setTitle: @"Handmade Hero"];
    [Window setAcceptsMouseMovedEvents: YES];
    [Window setOpaque: YES];
    [Window center];
    [Window makeKeyAndOrderFront: nil];
    Window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;

    osx_window_dimension Dimension = OSXGetWindowDimension(Window);
    OSXResize(&GlobalBackBuffer, Dimension.Width, Dimension.Height);

    real64 MonitorRefreshHz = 60;
    real64 OSXRefreshRate = OSXDisplayRefreshRate();
    if(OSXRefreshRate > 0.0)
    {
        MonitorRefreshHz = OSXRefreshRate;
    }
    real32 GameUpdateHz = (real32)(MonitorRefreshHz / 2.0);
    real32 TargetSecondsPerFrame = 1.0f / (real32)GameUpdateHz;

    // TODO: (Kapsy) Move to a catch all init function?
    OSXGetAudioHardwareProperties(&GlobalAudioBuffer);

    GlobalAudioBuffer.BitsPerChannel = 16;
    GlobalAudioBuffer.BytesPerFrame =
        (GlobalAudioBuffer.BitsPerChannel / BitsPerByte) *
        GlobalAudioBuffer.ChannelCount;
    // TODO: (Kapsy) Make this like 60 seconds?
    GlobalAudioBuffer.Size = (GlobalAudioBuffer.HardwareChunkSizeFrames * GlobalAudioBuffer.BytesPerFrame) * 80;

    GlobalAudioBuffer.StartCursor =
    GlobalAudioBuffer.ReadCursor =
    // GlobalAudioBuffer.WriteCursor =
        mmap(GlobalAudioBuffer.StartCursor, GlobalAudioBuffer.Size,
                PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON,
                -1, 0);

    GlobalAudioBuffer.WriteIndex +=
        (GlobalAudioBuffer.HardwareChunkSizeFrames * GlobalAudioBuffer.BytesPerFrame);
    GlobalAudioBuffer.WriteCursor =
        (void *)
        ((uint8 *)GlobalAudioBuffer.StartCursor +
         (GlobalAudioBuffer.HardwareChunkSizeFrames * GlobalAudioBuffer.BytesPerFrame));
    GlobalAudioBuffer.EndCursor =
        (void *)
        ((uint8 *)GlobalAudioBuffer.StartCursor + GlobalAudioBuffer.Size);

    // GlobalAudioBuffer.WritePosition =
    //     (GlobalAudioBuffer.HardwareChunkSizeFrames * GlobalAudioBuffer.BytesPerFrame);
    GlobalAudioBuffer.RunningIndex = 0;
    AudioCallbackFlipTime = mach_absolute_time();
    OSXStartAudioHardware(&GlobalAudioBuffer);


    HIDManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    // TODO: (Kapsy) Multiple Matching Dictionaries.
    CFMutableArrayRef MatchingArray =
        CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if(MatchingArray)
    {
        CFMutableDictionaryRef KeyboardDictionary =
            OSXHIDDeviceDictionary(kHIDPage_GenericDesktop, kHIDUsage_GD_Keyboard);
        if(KeyboardDictionary)
        {
            CFArrayAppendValue(MatchingArray, KeyboardDictionary);
            CFRelease(KeyboardDictionary);
        }
        else
        {
            // TODO: (Kapsy) Logging.
        }
        CFMutableDictionaryRef MouseDictionary =
            OSXHIDDeviceDictionary(kHIDPage_GenericDesktop, kHIDUsage_GD_Mouse);
        if(MouseDictionary)
        {
            CFArrayAppendValue(MatchingArray, MouseDictionary);
            CFRelease(MouseDictionary);
        }
        else
        {
            // TODO: (Kapsy) Logging.
        }
        // TODO: (Kapsy) Add support for XBox360 Controller/Gamepad.
        IOHIDManagerSetDeviceMatchingMultiple(HIDManager, MatchingArray);
        // TODO: (Kapsy) Register IOHIDManagerRegisterDeviceRemovalCallback etc to detect hot swapping...
        IOHIDManagerRegisterDeviceMatchingCallback(HIDManager, OSXHIDMatchingCallback, nil);
        IOHIDManagerScheduleWithRunLoop(HIDManager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    }

    GlobalRunning = true;

#if HANDMADE_INTERNAL
    uint64 BaseAddressBytes = (uint64)Terabytes(2);
#else
    // TODO: (Kapsy) Define flags here so that MAP_FIXED isn't used.
    uint64 BaseAddressBytes = 0;
#endif

    // TODO: (Kapsy) Rename to HoldingBuffer.
    // TODO: (Kapsy) Pool with bitmap mmap.
    int16 *SoundSampleBuffer = 0;
    uint32 SoundSampleBufferSize = GlobalAudioBuffer.Size;

    SoundSampleBuffer = (int16 *)mmap(SoundSampleBuffer, SoundSampleBufferSize,
            PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON,
            -1, 0);

    game_memory GameMemory = {};
    GameMemory.PermanentStorageSize = Megabytes(64);
    GameMemory.TransientStorageSize = Gigabytes(1);
    GameMemory.DEBUGPlatformFreeFileMemory = DEBUGPlatformFreeFileMemory;
    GameMemory.DEBUGPlatformReadEntireFile = DEBUGPlatformReadEntireFile;
    GameMemory.DEBUGPlatformWriteEntireFile = DEBUGPlatformWriteEntireFile;


    // TODO: (Kapsy) Maybe not the right way to go, might have to use size types
    // in engine_memory.
    // size TotalMemorySize =
        // SafeTruncateUint64(GameMemory.PermanentStorageSize + GameMemory.TransientStorageSize);

        // TODO: (Kapsy) Work out what this means for OSX:
            // TODO(casey): Handle various memory footprints (USING
            // SYSTEM METRICS)

            // TODO(casey): Use MEM_LARGE_PAGES and
            // call adjust token privileges when not on Windows XP?

            // TODO(casey): TransientStorage needs to be broken up
            // into game transient and cache transient, and only the
            // former need be saved for state playback.
    OSXState.TotalSize =
        GameMemory.PermanentStorageSize + GameMemory.TransientStorageSize;

    uint64 PageSize = getpagesize();
    Assert(BaseAddressBytes % PageSize == 0);
    Assert(OSXState.TotalSize % PageSize == 0);

    // TODO: (Kapsy): Use large Mem Pages? Is there a way to do so with mmap?
    void *BaseAddress = (void *)BaseAddressBytes;
    OSXState.GameMemoryBlock =
        mmap(BaseAddress, OSXState.TotalSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);

    GameMemory.PermanentStorage = OSXState.GameMemoryBlock;
    GameMemory.TransientStorage =
        ((uint8 *)GameMemory.PermanentStorage + GameMemory.PermanentStorageSize);


    for(int ReplayIndex = 1;
            ReplayIndex < ArrayCount(OSXState.ReplayBuffers);
            ++ReplayIndex)
    {
        osx_replay_buffer *ReplayBuffer = &OSXState.ReplayBuffers[ReplayIndex];

        OSXGetInputFilePath(&OSXState, false, ReplayIndex,
                sizeof(ReplayBuffer->Filename), ReplayBuffer->Filename);

        ReplayBuffer->FileHandle =
            open(ReplayBuffer->Filename, O_RDWR | O_CREAT | O_TRUNC,
                    S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH);

        if(ReplayBuffer->FileHandle)
        {
            int Result = ftruncate(ReplayBuffer->FileHandle, OSXState.TotalSize);

            if(Result == 0)
            {
                ReplayBuffer->MemoryBlock = mmap(0, OSXState.TotalSize,
                        PROT_READ|PROT_WRITE,
                        MAP_PRIVATE,
                        ReplayBuffer->FileHandle,
                        0);
            }
        }
    }

    if(SoundSampleBuffer != MAP_FAILED &&
            GameMemory.PermanentStorage != MAP_FAILED &&
            GameMemory.TransientStorage != MAP_FAILED)
    {

        mach_timebase_info_data_t MachTimebaseInfo;
        mach_timebase_info(&MachTimebaseInfo);


        game_input Input[2] = {};
        game_input *NewInput = &Input[0];
        game_input *OldInput = &Input[1];

        uint64 LastMachTime = mach_absolute_time();
        uint64 FlipMachTime = mach_absolute_time();

        // TODO: (Kapsy) Going to leave for now, but the basic idea is that
        // we should be using the WriteCursor, so even with a very
        // big buffer the latency should be minimal.
        // Have to remember that what we're drawing is the
        // POSITION OF THE FRAME IN TIME IN RELATION TO THE BUFFER.
        // Unfortunately it's not that accurate but I don't think that theres
        // much we can do about that. 11.6ms per frame means were going to be
        // straddling between 2 and 3 (maybe sometimes 4) Callbacks per frame.
        int DebugTimeMarkerIndex = 0;
        osx_debug_time_marker DebugTimeMarkers[10] = {0};

        // TODO: (Kapsy) Should probably be using this to set our initial
        // Audio Buffer state.
        bool32 AudioIsValid = false;

        osx_game_code Game =
            OSXLoadGameCode(SourceGameCodeDLFullPath, TempGameCodeDLFullPath, GameCodeLockFullPath);
        uint32 LoadCounter = 0;

        while(GlobalRunning)
        {
            NewInput->dtForFrame = TargetSecondsPerFrame;

            time_t NewDLWriteTime = OSXGetLastWriteTime(SourceGameCodeDLFullPath);
            if(NewDLWriteTime > Game.LastDLWriteTime)
            {
                OSXUnloadGameCode(&Game);
                Game = OSXLoadGameCode(SourceGameCodeDLFullPath, TempGameCodeDLFullPath, GameCodeLockFullPath);
                LoadCounter = 0;
            }

            // TODO: (Kapsy) Move to function as we're doing this for KB too.
            for(int ButtonIndex = 0;
                    ButtonIndex < ArrayCount(NewInput->MouseButtons);
                    ++ButtonIndex)
            {
                NewInput->MouseButtons[ButtonIndex].EndedDown =
                    OldInput->MouseButtons[ButtonIndex].EndedDown;
                NewInput->MouseButtons[ButtonIndex].HalfTransitionCount = 0;
            }

            // NOTE: (Kapsy) The autoreleasepool takes _most_ of the
            // game loop time. Between about 12-17ms, nearly _all_ of the game
            // loop time @60fps.

            // NOTE: (Kapsy) This is how the loop works in it's current state:
            // setNeedsDisplay doesn't actually directly call drawRect.
            // It would seem that the draw call is added as an Event to the
            // default run loop. I know this because the run loop (autoreleasepool)
            // takes 12-17ms when calling setNeedsDisplay, but when not calling it
            // the entire Game Loop only takes 2-3ms.
            // TODO: (Kapsy) Confirm - are we introducing an extra frame of latency?
            @autoreleasepool
            {
                NSEvent *Event;
                do
                {
                    Event =
                        [NSApp nextEventMatchingMask: NSAnyEventMask
                        untilDate: nil
                            inMode: NSDefaultRunLoopMode
                            dequeue: YES];
                    if(Event)
                    {
                        [NSApp sendEvent: Event];

                        switch(Event.type)
                        {
                            case NSLeftMouseDown:
                                {
                                    // TODO: (Kapsy) Need to reset half transition count between frames.
                                    OSXProcessKeyboardMessage(&NewInput->MouseButtons[0], true);
                                } break;
                            case NSLeftMouseUp:
                                {
                                    OSXProcessKeyboardMessage(&NewInput->MouseButtons[0], false);
                                } break;
                            case NSRightMouseDown:
                                {
                                    OSXProcessKeyboardMessage(&NewInput->MouseButtons[1], true);
                                } break;
                            case NSRightMouseUp:
                                {
                                    OSXProcessKeyboardMessage(&NewInput->MouseButtons[1], false);
                                } break;
                            case NSMouseMoved:
                                {
                                } break;
                            case NSLeftMouseDragged:
                                {
                                } break;
                            case NSRightMouseDragged:
                                {
                                } break;
                            case NSMouseEntered:
                                {
                                } break;
                            case NSMouseExited:
                                {
                                } break;
                            case NSScrollWheel:
                                {
                                    // NSLog(@"deltaX:%f deltaY:%f", Event.deltaX, Event.deltaY);
                                } break;
                            case NSOtherMouseDown:
                                {
                                    /*
                                    NOTE: (Kapsy) Logitech MX500 configuration:

                                    Left: 0
                                    Right: 1
                                    Middle (Scroll Wheel): 2
                                    Back: 3
                                    Forward: 4
                                    Function: 5
                                    Scroll Up: 6
                                    Scroll Down: 7
                                    */

                                    // TODO: (Kapsy) Just a hack for the MX500, should be able to
                                    // query how many buttons the hardware has, will probably have to use IOKit?
                                    uint32 ButtonNumber = (uint32)Event.buttonNumber;
                                    if(ButtonNumber < 5)
                                    {
                                        OSXProcessKeyboardMessage(&NewInput->MouseButtons[ButtonNumber], true);
                                    }

                                } break;
                            case NSOtherMouseUp:
                                {
                                    uint32 ButtonNumber = (uint32)Event.buttonNumber;
                                    if(ButtonNumber < 5)
                                    {
                                        OSXProcessKeyboardMessage(&NewInput->MouseButtons[ButtonNumber], false);
                                    }
                                } break;
                            case NSOtherMouseDragged:
                                {
                                } break;
                        }

#if 0
                        if(Event.type == NSKeyDown)
                        {
                            unichar C = [[Event charactersIgnoringModifiers] characterAtIndex:0];
                            int ModifierFlags = [Event modifierFlags];
                            int CommandKeyFlag = ModifierFlags & NSCommandKeyMask;
                            int ControlKeyFlag = ModifierFlags & NSControlKeyMask;
                            int AlternateKeyFlag = ModifierFlags & NSAlternateKeyMask;

                            NSLog(@"NSKeyDown:%d Cmd:%d Ctl:%d Alt:%d",
                                    C, CommandKeyFlag, ControlKeyFlag, AlternateKeyFlag);
                            // NOTE: (Kapsy) Can get modifier state using
                            // Event.modifierFlags, but only with a primary key,
                            // not the modifier itself.
                        }
                        if(Event.type == NSFlagsChanged)
                        {
                            NSLog(@"NSFlagsChanged!");
                        }
#endif
                    }
                }
                while(Event);
            }

            // TODO: (Kapsy) Need to account for all controllers when we get a 360 controller.
            // TODO: (Kapsy): Zeroing macro
            // TODO: (Kapsy): We can't zero everything because the up/down state will
            // be wrong!!!
            game_controller_input *OldKeyboardController = GetController(OldInput, 0);
            game_controller_input *NewKeyboardController = GetController(NewInput, 0);
            *NewKeyboardController = (game_controller_input){ 0 };
            NewKeyboardController->IsConnected = true;
            for(int ButtonIndex = 0;
                    ButtonIndex < ArrayCount(NewKeyboardController->Buttons);
                    ++ButtonIndex)
            {
                NewKeyboardController->Buttons[ButtonIndex].EndedDown =
                    OldKeyboardController->Buttons[ButtonIndex].EndedDown;
            }

            OSXProcessPendingKeyboardMessages(&OSXState, NewKeyboardController);

            if(!GlobalPause)
            {
                NSRect ContentViewInScreen = [Window convertRectToScreen:[[Window contentView] frame]];
                // TODO: (Kapsy) Probably easier just to work out the relative co-ords, then we can
                // include a margin and convert to the Games Co-ord space etc.
                CGPoint MouseInScreen = [NSEvent mouseLocation];
                BOOL MouseIsInContentView = NSPointInRect(MouseInScreen, ContentViewInScreen);
                if(MouseIsInContentView)
                {
                    // TODO: (Kapsy) We might want a margin so that we can draw a
                    // cursor as it falls off the screen
                    CGPoint MouseInContentView = CGPointMake(
                            (MouseInScreen.x - ContentViewInScreen.origin.x),
                            (MouseInScreen.y - ContentViewInScreen.origin.y));

                    NewInput->MouseX = MouseInContentView.x;
                    NewInput->MouseY = ContentViewInScreen.size.height - MouseInContentView.y;
                    NewInput->MouseZ = 0;
                }

                if(GlobalLoop)
                {
                    if(OSXState.InputPlayingIndex == 0)
                    {
                        if(OSXState.InputRecordingIndex == 0)
                        {
                            OSXBeginRecordingInput(&OSXState, 1);
                        }
                        else
                        {
                            OSXEndRecordingInput(&OSXState);
                            OSXBeginInputPlayback(&OSXState, 1);
                        }
                    }
                    else
                    {
                        OSXEndInputPlayback(&OSXState);
                    }

                    GlobalLoop = false;
                }

                thread_context Thread = {};

                game_offscreen_buffer Buffer = {};
                Buffer.Memory = GlobalBackBuffer.Memory;
                Buffer.Width = GlobalBackBuffer.Width;
                Buffer.Height = GlobalBackBuffer.Height;
                Buffer.Pitch = GlobalBackBuffer.Pitch;
                Buffer.BytesPerPixel = GlobalBackBuffer.BytesPerPixel;

                if(OSXState.InputRecordingIndex)
                {
                    OSXRecordInput(&OSXState, NewInput);
                }

                if(OSXState.InputPlayingIndex)
                {
                    OSXPlaybackInput(&OSXState, NewInput);
                }

                if(Game.UpdateAndRender)
                {
                    Game.UpdateAndRender(&Thread, &GameMemory, NewInput, &Buffer);
                }


                /*
                  NOTE: (Kapsy)

                  Want to approach this in two steps:

                  First, with the premise that the Sound Card _is_ low latency.

                  So we need to find our position within the audio buffer at the time of
                  flipping and/or the time of calcing our audio.

                  At the time of calc'ing audio we then need to take that position, and add
                  the REMAINDER of the frame time in Audio Bytes.

                  This will give us our next frame position within the Audio Buffer.
                  NOTE: This is not our write position, but in order to maintain accurate
                  synchronization, we have to work out our flip position relative
                  to the Audio Buffer every time.

                  We then simply write from the RunningIndex up until the flip position _plus_
                  one frames worth of Audio Bytes.

                  This should set the RunningIndex to the next flip, but since small errors would
                  acculmulate if we just relied on this position as our start write we need to
                  work out the flip for each frame.

                  A brute force way would be to just add HardwareChunkSize to the WriteSize.
                  I think a better way would be to take the clock time for each Callback start,
                  and subtract it from the clock time at writing.

                  This should give us the position within the Audio Buffer in Bytes, where we can
                  then simply count to the flip position.
                 */


                // TODO: (Kapsy) Need to make sure all of our initialization is correct here.
                // TODO: (Kapsy) Handle High Latency/High Framerate here.
                uint32 FrameRateBytes =
                    (GlobalAudioBuffer.FrameRate * GlobalAudioBuffer.BytesPerFrame);

                uint32 AudioBytesPerFrame =
                    FrameRateBytes * TargetSecondsPerFrame;

                uint32 ReadCursor =
                    GlobalAudioBuffer.ReadIndex % GlobalAudioBuffer.Size;

                uint32 WriteCursor =
                    GlobalAudioBuffer.WriteIndex % GlobalAudioBuffer.Size;

                uint64 AudioCallbackFlipMachTime = AudioCallbackFlipTime;
                uint64 WriteAudioMachTime = mach_absolute_time();

                /* TODO: (Kapsy) To try and solve this:
                   Find out what the diff in bytes is between the Render Callbacks time
                   and a grabbed mach time.
                   Start an IOProc render callback and log all the times passed back -
                   See if one corresponds to the AU render callback time.

                   Ok, so appears that our difference is pretty consistent.
                   And while it's not 512, it may be taking into account the actual H/W
                   latency value (399) on the MBP.

                       AudioCallbackFlipElapsedSeconds:0.007710
                       AudioCallbackFlipElapsedBytes:1359
                       FlipTimeDifferenceFrames:646
                       FlipTimeDifferenceFrames:641
                       FlipTimeDifferenceFrames:646

                 */

                Assert(AudioCallbackFlipMachTime < WriteAudioMachTime);

                real32 AudioCallbackFlipElapsedSeconds =
                    SFromNS(WriteAudioMachTime - AudioCallbackFlipMachTime *
                            (MachTimebaseInfo.numer/MachTimebaseInfo.denom));
                // NSLog(@"AudioCallbackFlipElapsedSeconds:%f", AudioCallbackFlipElapsedSeconds);
                // TODO: (Kapsy) Round this value!
                uint32 AudioCallbackFlipElapsedBytes =
                    (uint32)((real32)FrameRateBytes * AudioCallbackFlipElapsedSeconds);
                // NOTE: (Kapsy) As we're a 16bit value should range from about
                // 0 - 2000 on MBP.
                // NSLog(@"AudioCallbackFlipElapsedBytes:%d", AudioCallbackFlipElapsedBytes);

                uint32 AbsoluteReadIndex =
                    GlobalAudioBuffer.ReadIndex + AudioCallbackFlipElapsedBytes;

                // TODO: (Kapsy) Move to convenience function.
                uint32 WriteAudioElapsedNS =
                    (WriteAudioMachTime - FlipMachTime) *
                    (MachTimebaseInfo.numer/MachTimebaseInfo.denom);
                real32 WriteAudioElapsedS =
                    SFromNS(WriteAudioElapsedNS);
                uint32 WriteAudioElapsedBytes =
                    (uint32)(WriteAudioElapsedS * (real32)FrameRateBytes);

                uint32 AudioBytesUntilNextFlip = AudioBytesPerFrame - WriteAudioElapsedBytes;

                // TODO: (Kapsy) In this case we can more or less ensure that the
                // Running index is no longer valid and will need to be reset too.
                // Still not happy with initialization.
                if(WriteAudioElapsedBytes > AudioBytesPerFrame)
                {
                    AudioBytesUntilNextFlip = 0;
                    GlobalAudioBuffer.RunningIndex = GlobalAudioBuffer.WriteIndex + AudioBytesUntilNextFlip;
                }

                uint32 WriteStart =
                    GlobalAudioBuffer.RunningIndex % GlobalAudioBuffer.Size;

                // TODO: (Kapsy) Set the the Write index _if_ we are not going to meet the Frame Flip.
                uint32 WriteEnd =
                    (AbsoluteReadIndex + AudioBytesUntilNextFlip + AudioBytesPerFrame) %
                    GlobalAudioBuffer.Size;

                uint32 WriteSize = 0;

                if(WriteStart > WriteEnd)
                {
                    WriteSize = GlobalAudioBuffer.Size - WriteStart;
                    WriteSize += WriteEnd;
                }
                else
                {
                    WriteSize = WriteEnd - WriteStart;
                }

                game_sound_buffer GameSoundBuffer = {};
                GameSoundBuffer.FrameRate = GlobalAudioBuffer.FrameRate;
                GameSoundBuffer.FrameCount =
                    WriteSize / GlobalAudioBuffer.BytesPerFrame;
                GameSoundBuffer.Samples = SoundSampleBuffer;

                if(Game.GetSoundSamples)
                {
                    Game.GetSoundSamples(&Thread, &GameMemory, &GameSoundBuffer);
                }

                OSXFillAudioBuffer(&GameSoundBuffer, &GlobalAudioBuffer, WriteStart, WriteEnd);

                real32 WorkElapsedNS = MachTimeElapsedNS(LastMachTime, MachTimebaseInfo);
                real32 TargetNSPerFrame = NSFromS(TargetSecondsPerFrame);
                real32 FrameElapsedNS = WorkElapsedNS;
                // TODO: (Kapsy) Probably a much more efficient way than adding a
                // sleep buffer.
                real32 SleepBufferNS = NSFromMS(6);

                // TODO: (Kapsy) NOT TESTED YET!
                if(FrameElapsedNS < (TargetNSPerFrame - SleepBufferNS))
                {
                    real32 SleepNS = TargetNSPerFrame - FrameElapsedNS;
                    real32 SleepUS = USFromNS(SleepNS - SleepBufferNS);
                    // TODO: (Kapsy) Use nanosleep!
                    // nanosleep(SleepNS);

                    // TODO: (Kapsy) Use timing functions we discovered with the
                    // first iteration of SeiSO. Also check out high priority timing thread.
                    usleep(SleepUS);

                    // real32 TestElapsedNS = MachTimeElapsedNS(LastMachTime, MachTimebaseInfo);
                    // Assert(TestElapsedNS < TargetNSPerFrame);

                    while(FrameElapsedNS < TargetNSPerFrame)
                    {
                        real32 SpinlockElapsedNS = MachTimeElapsedNS(LastMachTime, MachTimebaseInfo);
                        FrameElapsedNS = SpinlockElapsedNS;
                    }
                }
                else
                {
                    // TODO: (Kapsy) Missed frame rate.
                    // TODO: (Kapsy) Logging.
                    NSLog(@"MISSED FRAME RATE");
                }

#if HANDMADE_INTERNAL
                {
                    osx_debug_time_marker *Marker = &DebugTimeMarkers[DebugTimeMarkerIndex];

                    uint32 ReadCursorAbsolute =
                        AbsoluteReadIndex % GlobalAudioBuffer.Size;

                    Marker->ReadCursor = ReadCursor;
                    Marker->ReadCursorAbsolute = ReadCursorAbsolute;
                    Marker->WriteCursor = WriteCursor;
                    Marker->WriteStart = WriteStart;
                    Marker->WriteEnd = WriteEnd;
                }
#endif

#if 1
                OSXDebugSyncDisplay(
                        &GlobalBackBuffer,
                        ArrayCount(DebugTimeMarkers),
                        DebugTimeMarkers,
                        DebugTimeMarkerIndex,
                        &GlobalAudioBuffer,
                        TargetSecondsPerFrame);

                ++DebugTimeMarkerIndex;
                if(DebugTimeMarkerIndex == ArrayCount(DebugTimeMarkers))
                {
                    DebugTimeMarkerIndex = 0;
                }
#endif

                [View setNeedsDisplay: YES];

                FlipMachTime = mach_absolute_time();

                uint64 EndMachTime = mach_absolute_time();
                uint64 ElapsedMachTime = EndMachTime - LastMachTime;
                uint64 ElapsedMachTimeNS =
                    ElapsedMachTime * (MachTimebaseInfo.numer/MachTimebaseInfo.denom);
                real64 MSPerFrame = (real64)ElapsedMachTimeNS / (real64)NSPerMS;
                real64 FPS = (real64)NSPerS / (real64)ElapsedMachTimeNS;
#pragma unused(MSPerFrame)
#pragma unused(FPS)

#if 0
                NSLog(@"%.02fms/f, %.02ff/s", MSPerFrame, FPS);
#endif

                LastMachTime = EndMachTime;
                // usleep(USFromS(1));

                game_input *Temp = NewInput;
                NewInput = OldInput;
                OldInput = Temp;

                // TODO: (Kapsy) Should these be being cleared?
            }
        }

    }
    else
    {
        NSLog(@"mmap error: %d %s\n", errno, strerror(errno));
    }

    return(0);
}
