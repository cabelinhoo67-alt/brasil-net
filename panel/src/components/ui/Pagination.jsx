export default function Pagination({ meta, onChange }) {
  if (!meta || meta.totalPages <= 1) return null;

  const { page, totalPages, total } = meta;

  return (
    <div className="flex items-center justify-between gap-3 border-t border-white/[0.06] px-4 py-3">
      <span className="text-[11px] text-ash-400">
        Pagina {page} de {totalPages} · {total} registro(s)
      </span>

      <div className="flex gap-1.5">
        <button
          disabled={page <= 1}
          onClick={() => onChange(page - 1)}
          className="rounded-lg border border-white/10 px-3 py-1.5 text-xs text-zinc-300 transition-colors hover:border-ember-500/40 hover:text-white disabled:opacity-30 disabled:hover:border-white/10"
        >
          Anterior
        </button>
        <button
          disabled={page >= totalPages}
          onClick={() => onChange(page + 1)}
          className="rounded-lg border border-white/10 px-3 py-1.5 text-xs text-zinc-300 transition-colors hover:border-ember-500/40 hover:text-white disabled:opacity-30 disabled:hover:border-white/10"
        >
          Proxima
        </button>
      </div>
    </div>
  );
}
