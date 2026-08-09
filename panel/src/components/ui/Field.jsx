const BASE =
  'w-full rounded-xl bg-void-800 border border-white/[0.07] px-3.5 py-2.5 text-sm text-zinc-100 ' +
  'placeholder:text-ash-400/70 transition-colors focus:border-ember-500/60 focus:bg-void-800 ' +
  'disabled:opacity-50 disabled:cursor-not-allowed';

export function Label({ children, hint }) {
  return (
    <span className="mb-1.5 flex items-baseline justify-between gap-2">
      <span className="text-xs font-medium text-ash-300">{children}</span>
      {hint && <span className="text-[11px] text-ash-400">{hint}</span>}
    </span>
  );
}

export function Input({ label, hint, error, className = '', ...props }) {
  return (
    <label className="block">
      {label && <Label hint={hint}>{label}</Label>}
      <input className={`${BASE} ${error ? 'border-bad-500/60' : ''} ${className}`} {...props} />
      {error && <span className="mt-1 block text-[11px] text-red-400">{error}</span>}
    </label>
  );
}

export function Textarea({ label, hint, rows = 3, className = '', ...props }) {
  return (
    <label className="block">
      {label && <Label hint={hint}>{label}</Label>}
      <textarea rows={rows} className={`${BASE} font-mono text-xs ${className}`} {...props} />
    </label>
  );
}

export function Select({ label, hint, children, className = '', ...props }) {
  return (
    <label className="block">
      {label && <Label hint={hint}>{label}</Label>}
      <select className={`${BASE} appearance-none ${className}`} {...props}>
        {children}
      </select>
    </label>
  );
}

export function Switch({ label, description, checked, onChange, disabled = false }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className="flex w-full items-center justify-between gap-4 rounded-xl border border-white/[0.07] bg-void-800 px-3.5 py-3 text-left disabled:opacity-50"
    >
      <span className="min-w-0">
        <span className="block text-sm text-zinc-200">{label}</span>
        {description && <span className="block text-[11px] text-ash-400">{description}</span>}
      </span>
      <span
        className={`relative h-6 w-11 shrink-0 rounded-full transition-colors ${
          checked ? 'bg-ember-600' : 'bg-void-600'
        }`}
      >
        <span
          className={`absolute top-0.5 size-5 rounded-full bg-white transition-all ${
            checked ? 'left-[22px]' : 'left-0.5'
          }`}
        />
      </span>
    </button>
  );
}
