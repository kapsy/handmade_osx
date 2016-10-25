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

#if !defined(OSX_HANDMADE_H)

struct osx_offscreen_buffer
{
    // NOTE(Kapsy): (Win32) Pixels are always 32 bits wide, Mem order BB GG RR XX
    // BUT --- NEED TO CONFIRM THIS ON OSX!
    CGContextRef Context;
    void *Memory;
    int Width;
    int Height;
    int Pitch;
    int BytesPerPixel;
};

struct osx_window_dimension
{
    int Width;
    int Height;
};


struct osx_audio_buffer
{
    real32 FrameRate;
    uint64 RunningIndex;
    uint32 BytesPerFrame;

    // NOTE: (Kapsy) At the moment the Game will only ever support 2 channels.
    uint32 ChannelCount;
    uint32 BitsPerChannel;

    // TODO: (Kapsy) Rename to DeviceBufferSizeFrames etc.
    // uint32 DeviceBufferSize;
    // uint32 DeviceBufferFrameCount;
    // uint32 HardwareChunkSize;
    uint32 HardwareChunkSizeFrames;

    // TODO: (Kapsy) Needed?
    AudioObjectID DefaultOutputDevice;

    void *StartCursor;
    void *ReadCursor;
    void *WriteCursor;
    // TODO: (Kapsy) Look at either removing End or Size.
    void *EndCursor;
    uint32 Size;

    uint64 ReadIndex;
    uint64 WriteIndex;

};

struct osx_debug_time_marker
{
    uint32 ReadCursor;
    uint32 ReadCursorAbsolute;

    uint32 WriteCursor;
    uint32 WriteStart;
    uint32 WriteEnd;
};

struct osx_game_code
{
    void *GameCodeDL;
    time_t LastDLWriteTime;

    // IMPORTANT: (Kapsy) Either of the callbacks can be 0!
    // You must check before calling.
    game_update_and_render *UpdateAndRender;
    game_get_sound_samples *GetSoundSamples;

    bool32 IsValid;
};

struct osx_keyboard_message
{
    UInt32 Usage;
    UInt32 IntegerValue;
};

#define OSX_STATE_FILE_NAME_COUNT PATH_MAX

struct osx_replay_buffer
{
    int FileHandle;
    char Filename[OSX_STATE_FILE_NAME_COUNT];
    void *MemoryBlock;
};

struct osx_state
{
    uint64 TotalSize;
    void *GameMemoryBlock;
    osx_replay_buffer ReplayBuffers[4];

    int RecordingHandle;
    int InputRecordingIndex;

    int PlaybackHandle;
    int InputPlayingIndex;

    char AppPath[OSX_STATE_FILE_NAME_COUNT];
    char *AppPathOnePastLastSlash;
};

#define OSX_HANDMADE_H
#endif
