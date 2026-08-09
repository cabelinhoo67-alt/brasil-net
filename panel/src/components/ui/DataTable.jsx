/**
 * Tabela que vira lista de cartoes no celular.
 *
 * `columns`: { key, header, render(row), className?, hideOnMobile? }
 * No desktop sai uma <table>; abaixo de md cada linha vira um cartao com
 * os rotulos ao lado dos valores — sem scroll horizontal.
 */
export default function DataTable({ columns, rows, rowKey = (r) => r.id, onRowClick, empty }) {
  if (!rows?.length) return empty ?? null;

  return (
    <>
      {/* Desktop */}
      <div className="hidden overflow-x-auto md:block">
        <table className="w-full border-collapse text-sm">
          <thead>
            <tr className="border-b border-white/[0.06]">
              {columns.map((col) => (
                <th
                  key={col.key}
                  className={`px-4 py-3 text-left text-[11px] font-semibold uppercase tracking-widest text-ash-400 ${col.className ?? ''}`}
                >
                  {col.header}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr
                key={rowKey(row)}
                onClick={onRowClick ? () => onRowClick(row) : undefined}
                className={`border-b border-white/[0.03] transition-colors hover:bg-ember-600/[0.06] ${
                  onRowClick ? 'cursor-pointer' : ''
                }`}
              >
                {columns.map((col) => (
                  <td key={col.key} className={`px-4 py-3 align-middle ${col.className ?? ''}`}>
                    {col.render(row)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Celular */}
      <div className="divide-y divide-white/[0.04] md:hidden">
        {rows.map((row) => (
          <div
            key={rowKey(row)}
            onClick={onRowClick ? () => onRowClick(row) : undefined}
            className={`space-y-2 px-4 py-4 ${onRowClick ? 'active:bg-ember-600/10' : ''}`}
          >
            {columns
              .filter((col) => !col.hideOnMobile)
              .map((col, index) => (
                <div
                  key={col.key}
                  className={
                    index === 0
                      ? ''
                      : 'flex items-center justify-between gap-3 text-sm'
                  }
                >
                  {index > 0 && <span className="cell-label">{col.header}</span>}
                  <div className={index === 0 ? '' : 'text-right'}>{col.render(row)}</div>
                </div>
              ))}
          </div>
        ))}
      </div>
    </>
  );
}
