const VARIANTS = {
  primary:
    'bg-gradient-to-b from-ember-500 to-ember-700 text-white border border-ember-400/40 hover:from-ember-400 hover:to-ember-600 shadow-[0_0_20px_-8px_rgba(230,33,43,0.9)]',
  ghost: 'bg-white/[0.03] text-zinc-200 border border-white/10 hover:bg-white/[0.07]',
  danger: 'bg-bad-500/15 text-red-300 border border-bad-500/40 hover:bg-bad-500/25',
  subtle: 'bg-transparent text-ash-300 border border-transparent hover:text-white hover:bg-white/5',
};

const SIZES = {
  sm: 'h-8 px-3 text-xs gap-1.5',
  md: 'h-10 px-4 text-sm gap-2',
  lg: 'h-12 px-6 text-sm gap-2',
};

export default function Button({
  variant = 'primary',
  size = 'md',
  loading = false,
  disabled = false,
  className = '',
  children,
  ...props
}) {
  return (
    <button
      disabled={disabled || loading}
      className={`inline-flex items-center justify-center rounded-xl font-semibold tracking-wide
        transition-all duration-150 disabled:opacity-40 disabled:cursor-not-allowed
        active:scale-[0.98] ${VARIANTS[variant]} ${SIZES[size]} ${className}`}
      {...props}
    >
      {loading && (
        <span className="size-3.5 rounded-full border-2 border-white/30 border-t-white animate-spin" />
      )}
      {children}
    </button>
  );
}
