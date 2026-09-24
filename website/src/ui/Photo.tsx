type Props = {
  name: string;
  alt: string;
  tone?: string;
  position?: string;
  portraitPosition?: string;
  eager?: boolean;
  className?: string;
  /** Skip the portrait crops (for media boxes that stay landscape on every viewport). */
  landscapeOnly?: boolean;
};

const W = [960, 1600, 2400];
const P = [750, 1125];

/**
 * Full-bleed responsive photo from public/media: <name>-{960,1600,2400}.{avif,webp} for landscape viewports and
 * <name>-p{750,1125}.{avif,webp} for portrait ones. `tone` paints the box while it loads.
 */
export function Photo({ name, alt, tone = '#1b1d21', position = '50% 50%', portraitPosition, eager, className, landscapeOnly }: Props) {
  const src = (w: number, ext: string) => `/media/${name}-${w}.${ext}`;
  const psrc = (w: number, ext: string) => `/media/${name}-p${w}.${ext}`;
  const portrait = '(max-aspect-ratio: 4/5)';
  return (
    <picture className={`photo ${className ?? ''}`} style={{ backgroundColor: tone }}>
      {!landscapeOnly && (
        <source media={portrait} type="image/avif" srcSet={P.map((w) => `${psrc(w, 'avif')} ${w}w`).join(', ')} sizes="100vw" />
      )}
      {!landscapeOnly && (
        <source media={portrait} type="image/webp" srcSet={P.map((w) => `${psrc(w, 'webp')} ${w}w`).join(', ')} sizes="100vw" />
      )}
      <source type="image/avif" srcSet={W.map((w) => `${src(w, 'avif')} ${w}w`).join(', ')} sizes="100vw" />
      <img
        src={src(1600, 'webp')}
        srcSet={W.map((w) => `${src(w, 'webp')} ${w}w`).join(', ')}
        sizes="100vw"
        alt={alt}
        loading={eager ? 'eager' : 'lazy'}
        decoding="async"
        style={{ ['--pos' as string]: position, ['--pos-portrait' as string]: portraitPosition ?? position }}
      />
    </picture>
  );
}
