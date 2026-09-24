/**
 * A fingertip on the car's glass: a soft contact disc plus a ring on each press, all driven by
 * numbers (so a paused timeline can be seeked frame by frame). Panel px.
 */
export class Finger {
  readonly el: HTMLDivElement;
  private dot: HTMLDivElement;
  private halo: HTMLDivElement;
  x = 0;
  y = 0;
  on = 0;
  press = 0;
  ring = 0;

  constructor(parent: HTMLElement) {
    this.el = document.createElement('div');
    this.el.className = 'dm-fg';
    this.halo = document.createElement('div');
    this.halo.className = 'dm-fg-ring';
    this.dot = document.createElement('div');
    this.dot.className = 'dm-fg-dot';
    this.el.append(this.halo, this.dot);
    parent.appendChild(this.el);
  }

  apply() {
    const s = 0.86 + 0.14 * this.on - 0.08 * this.press;
    const r = this.ring;
    this.el.style.opacity = String(Math.max(this.on, r > 0 && r < 1 ? 1 : 0));
    this.el.style.transform = `translate(${this.x}px, ${this.y}px)`;
    this.dot.style.opacity = String(this.on);
    this.dot.style.transform = `scale(${s})`;
    this.halo.style.opacity = r > 0 && r < 1 ? String(1 - r) : '0';
    this.halo.style.transform = `scale(${0.7 + 1.4 * r})`;
  }
}
