import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import { env } from '../config/env.js';

const ROUNDS = 10;

export const hashPassword = (plain) => bcrypt.hash(plain, ROUNDS);
export const comparePassword = (plain, hash) => bcrypt.compare(plain, hash);

/** Token do painel web (admin/master/revendedor). */
export function signPanelToken(user) {
  return jwt.sign({ sub: user.id, role: user.role, scope: 'panel' }, env.JWT_SECRET, {
    expiresIn: env.JWT_PANEL_EXPIRES,
  });
}

/** Token do aplicativo mobile (cliente final). */
export function signAppToken(user, deviceId) {
  return jwt.sign({ sub: user.id, role: user.role, scope: 'app', deviceId }, env.JWT_SECRET, {
    expiresIn: env.JWT_APP_EXPIRES,
  });
}

export function verifyToken(token) {
  return jwt.verify(token, env.JWT_SECRET);
}

const ALPHABET = 'abcdefghijkmnpqrstuvwxyz23456789';

export function randomPassword(length = 8) {
  let out = '';
  for (let i = 0; i < length; i += 1) {
    out += ALPHABET[Math.floor(Math.random() * ALPHABET.length)];
  }
  return out;
}

/** Gera um usuario curto e legivel, ex.: "cli7f3k2". */
export function randomUsername(prefix = 'cli') {
  return `${prefix}${randomPassword(5)}`;
}
