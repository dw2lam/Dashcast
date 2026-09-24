// WebRTC media transport, used when the server picks `config.transport === "webrtc"`:
// HTTP mode (not a secure context → no WebCodecs), or ?forceWebRTC=1 for testing.
// The WebSocket keeps carrying control, input, pings and stats.
//
// The server sends a complete offer (no trickle); we answer after ICE gathering finishes.
// Video + audio play through one <video> element, letterboxed with object-fit: contain.
// Audio stays muted until the tap-to-start gesture (and always with ?mute=1).
//
// NOTE (Tesla): the car pauses <video> elements while in Drive, so this path is
// parked-only. The WebSocket + canvas path (WebCodecs / JPEG) keeps running in Drive.

export interface RtcStats {
  fps: number;
  decodeMs: number | null;
  dropped: number;
  latencyMs: number | null;
  jitterMs: number | null;
  audioBufferMs: number | null;
  rttMs: number | null;
  framesDecoded: number;
  width: number;
  height: number;
  codec: string;
  decoder: string;
}

const FIELDS = [
  'framesPerSecond',
  'framesDecoded',
  'totalDecodeTime',
  'framesDropped',
  'jitterBufferDelay',
  'jitterBufferEmittedCount',
  'frameWidth',
  'frameHeight',
  'codecId',
  'decoderImplementation',
];

export class RtcOut {
  state = 'idle';
  stats: RtcStats | null = null;
  private pc: RTCPeerConnection | null = null;
  private cinema = false;
  private audible = false;
  private prev: any = null;
  private prevT = 0;
  private guard = 0;

  constructor(
    private el: HTMLVideoElement,
    private send: (o: object) => void,
    private onFail: (why: string) => void,
    onSize: (w: number, h: number) => void,
    onPlaying: () => void,
  ) {
    const size = () => el.videoWidth && onSize(el.videoWidth, el.videoHeight);
    el.addEventListener('loadedmetadata', size);
    el.addEventListener('resize', size);
    el.addEventListener('playing', () => onPlaying());
  }

  get active(): boolean {
    return !!this.pc;
  }

  async offer(sdp: string): Promise<void> {
    this.close();
    const pc = new RTCPeerConnection({ iceServers: [] });
    this.pc = pc;
    this.state = 'negotiating';
    pc.ontrack = (e) => {
      const el = this.el;
      const s = e.streams && e.streams[0] ? e.streams[0] : new MediaStream([e.track]);
      if (el.srcObject !== s) el.srcObject = s;
      el.hidden = false;
      this.hints();
      this.play();
    };
    const watch = () => {
      if (pc !== this.pc) return;
      const st = (pc as any).connectionState || pc.iceConnectionState;
      this.state = st;
      if (st === 'connected' || st === 'completed') clearTimeout(this.guard);
      if (st === 'failed') this.fail('connection failed');
    };
    pc.oniceconnectionstatechange = watch;
    (pc as any).onconnectionstatechange = watch;

    await pc.setRemoteDescription({ type: 'offer', sdp });
    const answer = await pc.createAnswer();
    // Chrome configures its Opus decoder from its own answer, which omits stereo → mono downmix.
    answer.sdp = (answer.sdp || '').replace(/(a=fmtp:111 [^\r\n]*)/, (line) =>
      line.indexOf('stereo=1') >= 0 ? line : line + ';stereo=1;sprop-stereo=1');
    await pc.setLocalDescription(answer);
    // No trickle: wait for gathering to finish (bounded; host candidates only, so it's quick).
    await new Promise<void>((resolve) => {
      if (pc.iceGatheringState === 'complete') return resolve();
      const t = setTimeout(resolve, 3000);
      pc.onicegatheringstatechange = () => {
        if (pc.iceGatheringState === 'complete') {
          clearTimeout(t);
          resolve();
        }
      };
    });
    if (pc !== this.pc) return;
    this.send({ t: 'rtcAnswer', sdp: pc.localDescription!.sdp });
    this.state = 'connecting';
    this.guard = window.setTimeout(() => this.fail('timed out'), 10000);
  }

  private fail(why: string) {
    clearTimeout(this.guard);
    if (!this.pc) return;
    this.state = 'failed';
    this.onFail(why);
  }

  /** Latency mode → receiver playout target: interactive 0, cinema 250 ms. */
  setCinema(on: boolean): void {
    this.cinema = on;
    this.hints();
  }

  private hints() {
    if (!this.pc || !this.pc.getReceivers) return;
    for (const r of this.pc.getReceivers() as any[]) {
      if ('jitterBufferTarget' in r) r.jitterBufferTarget = this.cinema ? 250 : 0; // ms (Chrome 114+)
      if ('playoutDelayHint' in r) r.playoutDelayHint = this.cinema ? 0.25 : 0; // s (older Chrome)
    }
  }

  setAudible(on: boolean): void {
    this.audible = on;
    this.el.muted = !on;
    this.play();
  }

  private play() {
    this.el.muted = !this.audible;
    const p = this.el.play();
    if (p && p.catch) p.catch(() => {});
  }

  /** Poll getStats() (call once a second); deltas against the previous poll. */
  async poll(fallbackRttMs: number): Promise<RtcStats | null> {
    const pc = this.pc;
    if (!pc) return null;
    const rep = await pc.getStats();
    const v: any = {};
    const a: any = {};
    const byId: any = {};
    let rtt: number | null = null;
    rep.forEach((s: any) => {
      byId[s.id] = s;
      const kind = s.kind || s.mediaType;
      if (s.type === 'inbound-rtp' || s.type === 'track') {
        const t = kind === 'video' ? v : kind === 'audio' ? a : null;
        if (t) for (const k of FIELDS) if (s[k] != null && t[k] == null) t[k] = s[k];
      }
      if (s.type === 'candidate-pair' && s.state === 'succeeded' && (s.nominated || s.selected) && s.currentRoundTripTime != null)
        rtt = s.currentRoundTripTime * 1000;
    });
    const now = performance.now();
    const p = this.prev || {};
    const dt = this.prevT ? (now - this.prevT) / 1000 : 1;
    const d = (o: any, q: any, k: string) => (o[k] || 0) - ((q && q[k]) || 0);
    const dF = d(v, p.v, 'framesDecoded');
    const jb = (o: any, q: any) => {
      const n = d(o, q, 'jitterBufferEmittedCount');
      return n > 0 ? (d(o, q, 'jitterBufferDelay') / n) * 1000 : o.jitterBufferEmittedCount ? (o.jitterBufferDelay / o.jitterBufferEmittedCount) * 1000 : null;
    };
    const jitterMs = jb(v, p.v);
    if (rtt == null && fallbackRttMs >= 0) rtt = fallbackRttMs;
    const codec = v.codecId && byId[v.codecId] ? byId[v.codecId].mimeType || '' : '';
    this.prev = { v, a };
    this.prevT = now;
    return (this.stats = {
      fps: Math.round((v.framesPerSecond != null ? v.framesPerSecond : dF / dt) * 10) / 10,
      decodeMs: dF > 0 && v.totalDecodeTime != null ? (d(v, p.v, 'totalDecodeTime') / dF) * 1000 : null,
      dropped: Math.max(0, d(v, p.v, 'framesDropped')),
      latencyMs: jitterMs == null ? null : jitterMs + (rtt != null ? rtt / 2 : 0),
      jitterMs,
      audioBufferMs: jb(a, p.a),
      rttMs: rtt,
      framesDecoded: v.framesDecoded || 0,
      width: v.frameWidth || this.el.videoWidth,
      height: v.frameHeight || this.el.videoHeight,
      codec: codec.replace(/^video\//, ''),
      decoder: v.decoderImplementation || '',
    });
  }

  close(): void {
    clearTimeout(this.guard);
    const pc = this.pc;
    this.pc = null;
    this.prev = null;
    this.prevT = 0;
    this.stats = null;
    this.state = 'idle';
    if (pc) pc.close();
    this.el.srcObject = null;
    this.el.hidden = true;
  }
}
