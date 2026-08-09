import { prisma } from '../../lib/prisma.js';

/**
 * Normaliza o nome que vem do TelephonyManager.
 * O Android devolve coisas como "Claro BR", "VIVO", "TIM BRASIL", "Oi",
 * as vezes com espacos, acentos ou o nome do MVNO.
 */
function normalize(value = '') {
  return value
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, '');
}

/**
 * Resolve a operadora a partir dos dados lidos do SIM.
 * A ordem importa: MCC/MNC e a fonte confiavel; o nome e apenas fallback,
 * porque MVNOs e roaming distorcem a string do carrierName.
 *
 * @param {{ operatorName?: string, mccMnc?: string }} sim
 * @returns {Promise<import('@prisma/client').Operator|null>}
 */
export async function resolveOperator(sim) {
  const operators = await prisma.operator.findMany({ where: { isActive: true } });
  if (operators.length === 0) return null;

  const mccMnc = (sim.mccMnc || '').replace(/\D/g, '');
  if (mccMnc) {
    const byMccMnc = operators.find((op) =>
      op.mccMncList
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean)
        .includes(mccMnc),
    );
    if (byMccMnc) return byMccMnc;
  }

  const name = normalize(sim.operatorName);
  if (name) {
    // 1) codigo exato ("CLARO")
    const byCode = operators.find((op) => normalize(op.code) === name);
    if (byCode) return byCode;

    // 2) o nome do SIM contem o codigo ("CLAROBR" contem "CLARO")
    const byContains = operators.find((op) => name.includes(normalize(op.code)));
    if (byContains) return byContains;

    // 3) o nome cadastrado aparece no nome do SIM
    const byName = operators.find((op) => name.includes(normalize(op.name)));
    if (byName) return byName;
  }

  return null;
}
