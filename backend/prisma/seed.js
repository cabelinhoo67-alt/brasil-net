import { PrismaClient } from '@prisma/client';
import bcrypt from 'bcryptjs';

const prisma = new PrismaClient();

const OPERATORS = [
  { code: 'VIVO', name: 'Vivo', mccMncList: '72406,72410,72411,72423', sortOrder: 1 },
  { code: 'CLARO', name: 'Claro', mccMncList: '72405,72438', sortOrder: 2 },
  { code: 'TIM', name: 'TIM', mccMncList: '72402,72403,72404,72454', sortOrder: 3 },
  { code: 'OI', name: 'Oi', mccMncList: '72431,72416', sortOrder: 4 },
  { code: 'ALGAR', name: 'Algar Telecom', mccMncList: '72432,72433,72434', sortOrder: 5 },
  { code: 'VERO', name: 'Vero / Nextel', mccMncList: '72439', sortOrder: 6 },
];

const PLANS = [
  { name: 'Teste 1 dia', days: 1, connectionLimit: 1, creditCost: 0, priceCents: 0, isPublic: false, sortOrder: 0 },
  { name: 'Mensal 1 conexao', days: 30, connectionLimit: 1, creditCost: 1, priceCents: 2500, sortOrder: 1,
    description: '30 dias, 1 aparelho' },
  { name: 'Mensal 2 conexoes', days: 30, connectionLimit: 2, creditCost: 2, priceCents: 4000, sortOrder: 2,
    description: '30 dias, 2 aparelhos' },
  { name: 'Trimestral 1 conexao', days: 90, connectionLimit: 1, creditCost: 3, priceCents: 6500, sortOrder: 3,
    description: '90 dias, 1 aparelho' },
];

async function main() {
  const adminUsername = (process.env.ADMIN_USERNAME || 'admin').toLowerCase();
  const adminPassword = process.env.ADMIN_PASSWORD || 'admin123';

  const admin = await prisma.user.upsert({
    where: { username: adminUsername },
    update: {},
    create: {
      username: adminUsername,
      passwordHash: await bcrypt.hash(adminPassword, 10),
      role: 'ADMIN',
      fullName: 'Administrador Geral',
      credits: 0, // ADMIN tem credito ilimitado por regra de negocio
    },
  });
  console.log(`ADMIN: ${admin.username} / ${adminPassword}`);

  for (const op of OPERATORS) {
    await prisma.operator.upsert({ where: { code: op.code }, update: op, create: op });
  }
  console.log(`${OPERATORS.length} operadoras cadastradas`);

  for (const plan of PLANS) {
    await prisma.plan.upsert({ where: { name: plan.name }, update: plan, create: plan });
  }
  console.log(`${PLANS.length} planos cadastrados`);

  const server = await prisma.server.upsert({
    where: { id: '00000000-0000-4000-8000-000000000001' },
    update: {},
    create: {
      id: '00000000-0000-4000-8000-000000000001',
      name: 'Servidor BR-01',
      host: 'br01.seudominio.com.br',
      sshPort: 22,
      sslPort: 443,
      proxyPort: 80,
    },
  });

  // Um payload de exemplo por operadora, para o app ja ter o que listar.
  const operators = await prisma.operator.findMany();
  for (const op of operators) {
    const existing = await prisma.payload.findFirst({ where: { operatorId: op.id } });
    if (existing) continue;

    await prisma.payload.create({
      data: {
        name: `${op.name} - SSH/SSL padrao`,
        operatorId: op.id,
        serverId: server.id,
        mode: 'SSH_SSL',
        content: 'CONNECT [host_port] [protocol][crlf]Host: [host][crlf][crlf]',
        sni: `www.${op.code.toLowerCase()}.com.br`,
        sortOrder: 1,
      },
    });
  }
  console.log('Payloads de exemplo criados (1 por operadora)');

  // Revendedor de demonstracao com 50 creditos
  const reseller = await prisma.user.upsert({
    where: { username: 'revenda1' },
    update: {},
    create: {
      username: 'revenda1',
      passwordHash: await bcrypt.hash('revenda123', 10),
      role: 'RESELLER',
      fullName: 'Revendedor Demonstracao',
      parentId: admin.id,
      credits: 50,
    },
  });
  console.log(`REVENDEDOR: ${reseller.username} / revenda123 (50 creditos)`);

  // Cliente final de teste, 30 dias
  const testPlan = await prisma.plan.findUnique({ where: { name: 'Mensal 1 conexao' } });
  await prisma.user.upsert({
    where: { username: 'teste' },
    update: {},
    create: {
      username: 'teste',
      passwordHash: await bcrypt.hash('teste123', 10),
      role: 'CLIENT',
      fullName: 'Cliente de Teste',
      parentId: reseller.id,
      planId: testPlan?.id,
      connectionLimit: 1,
      expiresAt: new Date(Date.now() + 30 * 86_400_000),
    },
  });
  console.log('CLIENTE APP: teste / teste123 (30 dias)');

  await prisma.setting.upsert({
    where: { key: 'AUTO_SALE_OWNER_ID' },
    update: { value: admin.id },
    create: { key: 'AUTO_SALE_OWNER_ID', value: admin.id },
  });
}

main()
  .then(() => console.log('\nSeed concluido.\n'))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
