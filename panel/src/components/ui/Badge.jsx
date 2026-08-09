const TONES = {
  ok: 'bg-ok-500/12 text-emerald-300 border-ok-500/30',
  warn: 'bg-warn-500/12 text-amber-300 border-warn-500/30',
  bad: 'bg-bad-500/12 text-red-300 border-bad-500/30',
  ember: 'bg-ember-600/15 text-ember-300 border-ember-500/35',
  neutral: 'bg-white/[0.04] text-ash-300 border-white/10',
};

export default function Badge({ tone = 'neutral', children, className = '' }) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-lg border px-2 py-0.5 text-[11px] font-semibold ${TONES[tone]} ${className}`}
    >
      {children}
    </span>
  );
}

/** Ponto pulsante — usado para "online agora". */
export function LiveDot({ active }) {
  return (
    <span className="relative flex size-2">
      {active && (
        <span className="absolute inline-flex size-full rounded-full bg-ok-500 animate-ember" />
      )}
      <span
        className={`relative inline-flex size-2 rounded-full ${active ? 'bg-ok-500' : 'bg-void-600'}`}
      />
    </span>
  );
}
