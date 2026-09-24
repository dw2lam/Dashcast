// Query-string switches for testing on a desktop browser, e.g.
//   ?nowebcodecs=1  pretend WebCodecs is missing (JPEG, or WebRTC if the server offers it)
//   ?forceWebRTC=1  same claim (webcodecs:false) so the server picks the WebRTC transport
//   ?noworker=1     decode + render on the main thread
//   ?noworklet=1    ScriptProcessor audio instead of AudioWorklet
//   ?renderer=2d    Canvas 2D instead of WebGL
//   ?nobench=1      skip the decode bench
//   ?stats=1        open the stats overlay on load
//   ?mute=1         audio runs (buffer + A/V clock still measured) through a zero gain
//   ?ws=ws://host:port/ws  connect somewhere else
const q = new URLSearchParams(location.search);
const on = (k: string) => q.has(k) && q.get(k) !== '0';

export const flags = {
  noWebCodecs: on('nowebcodecs'),
  forceWebRTC: on('forceWebRTC') || on('forcewebrtc'),
  noWorker: on('noworker'),
  noWorklet: on('noworklet'),
  noBench: on('nobench'),
  stats: on('stats'),
  mute: on('mute'),
  renderer: q.get('renderer') || '',
  ws: q.get('ws') || '',
};
