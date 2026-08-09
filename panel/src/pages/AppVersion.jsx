import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import { useApi } from '../hooks/useApi';
import { useToast } from '../context/ToastContext';
import PageHeader from '../components/PageHeader';
import Button from '../components/ui/Button';
import { Input, Textarea } from '../components/ui/Field';
import { ErrorState, Loading } from '../components/ui/Feedback';

/**
 * Publicacao de versao OTA. O app compara pelo BUILD (inteiro), entao subir o
 * build e o que dispara a atualizacao nos aparelhos — a string de versao e so
 * o que o usuario ve.
 */
export default function AppVersion() {
  const { data, loading, error, reload } = useApi(() => api.appVersion.get(), []);
  const toast = useToast();
  const [form, setForm] = useState(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (data) {
      setForm({
        version: data.version ?? '',
        build: data.build ?? 0,
        apkUrl: data.apkUrl ?? '',
        changelog: data.changelog ?? '',
        minBuild: data.minBuild ?? 0,
        sizeMb: data.sizeBytes ? (data.sizeBytes / 1048576).toFixed(1) : '',
      });
    }
  }, [data]);

  async function onSubmit(event) {
    event.preventDefault();
    setSaving(true);
    try {
      await api.appVersion.set({
        version: form.version.trim(),
        build: Number(form.build),
        apkUrl: form.apkUrl.trim(),
        changelog: form.changelog,
        minBuild: Number(form.minBuild) || 0,
        sizeBytes: form.sizeMb ? Math.round(Number(form.sizeMb) * 1048576) : 0,
      });
      toast.success('Versao publicada. Os apps serao avisados no proximo ciclo.');
      reload();
    } catch (err) {
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  }

  if (loading) return <Loading label="Carregando versao..." />;
  if (error) return <ErrorState error={error} onRetry={reload} />;
  if (!form) return null;

  return (
    <>
      <PageHeader
        title="Versao do aplicativo (OTA)"
        description="Publique uma nova versao e o app oferece a atualizacao automaticamente."
      />

      <div className="grid gap-4 lg:grid-cols-3">
        <form onSubmit={onSubmit} className="card space-y-4 p-5 lg:col-span-2">
          <div className="grid gap-3 sm:grid-cols-3">
            <Input
              label="Versao (exibida)"
              value={form.version}
              onChange={(e) => setForm({ ...form, version: e.target.value })}
              placeholder="1.1.0"
              required
            />
            <Input
              label="Build"
              hint="e este numero que dispara o update"
              type="number"
              min={1}
              value={form.build}
              onChange={(e) => setForm({ ...form, build: e.target.value })}
              required
            />
            <Input
              label="Build minimo"
              hint="0 = opcional; abaixo disso e obrigatorio"
              type="number"
              min={0}
              value={form.minBuild}
              onChange={(e) => setForm({ ...form, minBuild: e.target.value })}
            />
          </div>

          <Input
            label="URL do APK"
            hint="link direto ao arquivo .apk arm64"
            value={form.apkUrl}
            onChange={(e) => setForm({ ...form, apkUrl: e.target.value })}
            placeholder="http://187.77.37.249:8091/tunnel-app.apk"
            required
          />

          <Input
            label="Tamanho (MB)"
            hint="mostrado ao usuario antes de baixar"
            type="number"
            step="0.1"
            value={form.sizeMb}
            onChange={(e) => setForm({ ...form, sizeMb: e.target.value })}
          />

          <Textarea
            label="Changelog"
            hint="uma novidade por linha"
            rows={5}
            value={form.changelog}
            onChange={(e) => setForm({ ...form, changelog: e.target.value })}
            placeholder={'Split tunneling para motoristas\nAtualizacao automatica\nCorrecoes de estabilidade'}
          />

          <Button type="submit" loading={saving}>
            Publicar versao
          </Button>
        </form>

        <div className="card h-fit p-5">
          <h3 className="mb-3 text-sm font-semibold text-white">Publicado agora</h3>
          <dl className="divide-y divide-white/[0.05]">
            {[
              ['Versao', data.version || '—'],
              ['Build', data.build || 0],
              ['Build minimo', data.minBuild || 0],
              ['APK', data.apkUrl ? 'configurado' : '—'],
            ].map(([k, v]) => (
              <div key={k} className="flex items-center justify-between gap-4 py-2.5">
                <dt className="text-xs text-ash-400">{k}</dt>
                <dd className="truncate text-sm text-zinc-200">{v}</dd>
              </div>
            ))}
          </dl>
          <p className="mt-4 rounded-xl border border-white/[0.06] bg-void-800/50 px-3 py-2 text-[11px] text-ash-400">
            A comparacao e por <span className="text-zinc-300">build</span>. Suba o build acima do
            instalado para que os apps ofereçam a atualizacao.
          </p>
        </div>
      </div>
    </>
  );
}
