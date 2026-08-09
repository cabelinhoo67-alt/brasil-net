import { useEffect } from 'react';
import Button from './Button';

export default function Modal({ open, onClose, title, subtitle, children, footer, size = 'md' }) {
  // Esc fecha e o body para de rolar enquanto o modal esta aberto.
  useEffect(() => {
    if (!open) return undefined;

    const onKey = (e) => e.key === 'Escape' && onClose?.();
    document.addEventListener('keydown', onKey);
    const previous = document.body.style.overflow;
    document.body.style.overflow = 'hidden';

    return () => {
      document.removeEventListener('keydown', onKey);
      document.body.style.overflow = previous;
    };
  }, [open, onClose]);

  if (!open) return null;

  const width = { sm: 'max-w-sm', md: 'max-w-lg', lg: 'max-w-2xl' }[size];

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center">
      <div
        className="absolute inset-0 bg-black/80 backdrop-blur-sm"
        onClick={onClose}
        aria-hidden="true"
      />

      <div
        role="dialog"
        aria-modal="true"
        className={`relative z-10 w-full ${width} max-h-[92dvh] overflow-y-auto rounded-t-3xl border border-ember-600/25 bg-void-900 shadow-[0_0_60px_-15px_rgba(230,33,43,0.45)] sm:rounded-2xl`}
      >
        <div className="sticky top-0 z-10 border-b border-white/[0.06] bg-void-900/95 px-5 py-4 backdrop-blur">
          <div className="flex items-start justify-between gap-4">
            <div className="min-w-0">
              <h2 className="text-base font-bold text-white">{title}</h2>
              {subtitle && <p className="mt-0.5 text-xs text-ash-400">{subtitle}</p>}
            </div>
            <button
              onClick={onClose}
              aria-label="Fechar"
              className="shrink-0 rounded-lg px-2 py-1 text-lg leading-none text-ash-400 hover:bg-white/5 hover:text-white"
            >
              &times;
            </button>
          </div>
        </div>

        <div className="px-5 py-5">{children}</div>

        {footer && (
          <div className="sticky bottom-0 border-t border-white/[0.06] bg-void-900/95 px-5 py-4 backdrop-blur">
            {footer}
          </div>
        )}
      </div>
    </div>
  );
}

/** Confirmacao para acoes destrutivas (excluir, derrubar sessoes). */
export function ConfirmModal({ open, onClose, onConfirm, title, message, confirmLabel = 'Confirmar', loading }) {
  return (
    <Modal
      open={open}
      onClose={onClose}
      title={title}
      size="sm"
      footer={
        <div className="flex gap-2">
          <Button variant="ghost" className="flex-1" onClick={onClose}>
            Cancelar
          </Button>
          <Button variant="danger" className="flex-1" onClick={onConfirm} loading={loading}>
            {confirmLabel}
          </Button>
        </div>
      }
    >
      <p className="text-sm text-ash-300">{message}</p>
    </Modal>
  );
}
