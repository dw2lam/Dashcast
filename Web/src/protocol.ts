// Wire contract: see ../../PROTOCOL.md (v1).
export const HEADER_BYTES = 16;
export const T_H264 = 1;
export const T_HEVC = 2;
export const T_JPEG = 3;
export const T_PCM = 4;

export type LatencyMode = 'interactive' | 'cinema';

export interface Config {
  t: 'config';
  transport?: 'ws' | 'webrtc';
  codec: string;
  width: number;
  height: number;
  fps: number;
  bitrateKbps: number;
  tier: string;
  latencyMode: LatencyMode;
  audio: { sampleRate: number; channels: number } | null;
  inputEnabled: boolean;
  serverTime: number;
}

export type InputKind = 'down' | 'move' | 'up' | 'scroll' | 'rightClick' | 'text' | 'key';

/** Target audio playout delay (capture pts -> speaker) per latency mode, in µs. */
export const PLAYOUT_US: Record<LatencyMode, number> = { interactive: 60000, cinema: 250000 };
