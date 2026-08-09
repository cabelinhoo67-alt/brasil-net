export function Spinner({ className = 'size-6' }) {
  return (
    <span
      className={`inline-block rounded-full border-2 border-ember-500/25 border-t-ember-500 animate-spin ${className}`}
    />
  );
}

export function Loading({ label = 'Carregando...' }) {
  return (
    <div className="flex flex-col items-center justify-center gap-3 py-16 text-ash-400">
      <Spinner />
      <span className="text-xs">{label}</span>
    </div>
  );
}

export function EmptyState({ icon = '·', title, description, action }) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 px-6 py-16 text-center">
      <span className="mb-1 grid size-12 place-items-center rounded-2xl border border-ember-600/25 bg-ember-600/5 text-xl text-ember-400">
        {icon}
      </span>
      <p className="text-sm font-semibold text-zinc-200">{title}</p>
      {description && <p className="max-w-sm text-xs text-ash-400">{description}</p>}
      {action && <div className="mt-3">{action}</div>}
    </div>
  );
}

export function ErrorState({ error, onRetry }) {
  return (
    <div className="flex flex-col items-center justify-center gap-3 px-6 py-14 text-center">
      <span className="grid size-12 place-items-center rounded-2xl border border-bad-500/30 bg-bad-500/10 text-xl">
        !
      </span>
      <p className="text-sm font-semibold text-red-300">Algo deu errado</p>
      <p className="max-w-sm text-xs text-ash-400">{error?.message ?? 'Erro desconhecido'}</p>
      {onRetry && (
        <button
          onClick={onRetry}
          className="mt-1 text-xs font-semibold text-ember-400 hover:text-ember-300"
        >
          Tentar novamente
        </button>
      )}
    </div>
  );
}
