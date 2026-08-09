import { prisma } from '../../lib/prisma.js';

/**
 * Informacao de versao do app, guardada em Settings (chave/valor).
 *
 * Fica em Setting em vez de uma tabela propria porque e um punhado de campos
 * globais, editados pelo painel e lidos pelo app — o mesmo padrao do
 * AUTO_SALE_OWNER_ID.
 */
const KEYS = {
  version: 'APP_LATEST_VERSION', // ex.: "1.1.0" (semver, o que o usuario ve)
  build: 'APP_LATEST_BUILD', // inteiro monotonico; e por ele que a comparacao decide
  apkUrl: 'APP_APK_URL', // URL direta do .apk arm64
  changelog: 'APP_CHANGELOG', // texto, uma novidade por linha
  minBuild: 'APP_MIN_BUILD', // abaixo disto a atualizacao e obrigatoria
  sizeBytes: 'APP_APK_SIZE', // tamanho do .apk, para a UI mostrar antes de baixar
};

function toInt(value, fallback = 0) {
  const n = Number.parseInt(value ?? '', 10);
  return Number.isFinite(n) ? n : fallback;
}

/** Le todas as chaves de versao de uma vez. */
export async function readVersionInfo() {
  const rows = await prisma.setting.findMany({
    where: { key: { in: Object.values(KEYS) } },
  });
  const map = Object.fromEntries(rows.map((r) => [r.key, r.value]));

  return {
    version: map[KEYS.version] ?? null,
    build: toInt(map[KEYS.build], 0),
    apkUrl: map[KEYS.apkUrl] ?? null,
    changelog: map[KEYS.changelog] ?? '',
    minBuild: toInt(map[KEYS.minBuild], 0),
    sizeBytes: toInt(map[KEYS.sizeBytes], 0),
  };
}

/**
 * Decide se o app precisa atualizar, comparando SEMPRE por build (inteiro),
 * nunca por string de versao — "1.10.0" < "1.9.0" em ordem alfabetica, e esse
 * tipo de bug em auto-update e caro.
 *
 * @param {number} currentBuild build instalado no aparelho
 */
export function evaluate(info, currentBuild) {
  const current = toInt(currentBuild, 0);
  const hasRelease = Boolean(info.apkUrl) && info.build > 0;

  const available = hasRelease && info.build > current;
  const mandatory = available && current < info.minBuild;

  return {
    updateAvailable: available,
    mandatory,
    latest: {
      version: info.version,
      build: info.build,
      apkUrl: info.apkUrl,
      changelog: info.changelog,
      sizeBytes: info.sizeBytes,
    },
    currentBuild: current,
  };
}

export async function setVersionInfo(input) {
  const entries = [];
  const put = (key, value) => value !== undefined && entries.push([key, String(value)]);

  put(KEYS.version, input.version);
  put(KEYS.build, input.build);
  put(KEYS.apkUrl, input.apkUrl);
  put(KEYS.changelog, input.changelog);
  put(KEYS.minBuild, input.minBuild);
  put(KEYS.sizeBytes, input.sizeBytes);

  await prisma.$transaction(
    entries.map(([key, value]) =>
      prisma.setting.upsert({ where: { key }, update: { value }, create: { key, value } }),
    ),
  );

  return readVersionInfo();
}
