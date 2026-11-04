// Phone lookup for Firebase sign-in (20261104000300_firebase_phone.sql).
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { rpc, sql, rejectsWith, closePool, createUser, nextPhone } from './lib/db.mjs';

after(closePool);

test('the service finds a login by phone in any format; customers cannot', async () => {
  const u = await createUser('phone');
  const phone = nextPhone();
  await sql(`update auth.users set phone = $2 where id = $1`, [u.id, phone.replace(/\D/g, '')]);
  assert.equal(await rpc('service', 'auth_user_id_for_phone', [phone]), u.id);
  assert.equal(await rpc('service', 'auth_user_id_for_phone', [phone.replace('+', '')]), u.id);
  assert.equal(await rpc('service', 'auth_user_id_for_phone', ['+910000000000']), null);
  await rejectsWith(rpc(u.id, 'auth_user_id_for_phone', [phone]), { sqlstate: '42501' });
});
