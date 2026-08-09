import { Router } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../../utils/http.js';
import { authenticate, requireRole } from '../../middlewares/auth.js';
import { readVersionInfo, setVersionInfo } from '../mobile/version.service.js';

const router = Router();
router.use(authenticate('panel'), requireRole('ADMIN'));

/** GET /api/settings/app-version — estado atual da publicacao OTA. */
router.get(
  '/app-version',
  asyncHandler(async (_req, res) => {
    res.json(await readVersionInfo());
  }),
);

const versionSchema = z.object({
  version: z.string().min(1).max(20).optional(),
  build: z.number().int().min(0).max(1_000_000).optional(),
  apkUrl: z.string().url().max(500).optional(),
  changelog: z.string().max(4000).optional(),
  minBuild: z.number().int().min(0).max(1_000_000).optional(),
  sizeBytes: z.number().int().min(0).optional(),
});

/**
 * PUT /api/settings/app-version
 * Publica uma nova versao para os clientes. Assim que o build aqui for maior
 * que o instalado, o app oferece a atualizacao no proximo ciclo de vida.
 */
router.put(
  '/app-version',
  asyncHandler(async (req, res) => {
    const input = versionSchema.parse(req.body);
    res.json(await setVersionInfo(input));
  }),
);

export default router;
