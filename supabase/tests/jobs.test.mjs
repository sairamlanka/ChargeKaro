import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { rpc, sql, one, closePool, approvedStation, as } from './lib/db.mjs';

after(closePool);

describe('compliance jobs', () => {
  test('expired documents are flagged once and do not suspend the station by default', async () => {
    const { owner, stationId } = await approvedStation();
    const doc = await one(
      `update public.station_documents set expires_on = current_date - 1
        where station_id = $1 and status = 'approved' returning id`, [stationId]);
    await rpc('service', 'run_compliance_jobs');
    await rpc('service', 'run_compliance_jobs');
    assert.equal((await one(`select status from public.station_documents where id = $1`, [doc.id])).status, 'expired');
    assert.equal((await one(`select status from public.stations where id = $1`, [stationId])).status, 'active');
    const notes = await as(owner.id, (q) => q(`select count(*)::int n from public.notifications where type = 'document.expired' and data->>'document_id' = $1`, [doc.id]));
    assert.equal(notes[0].n, 1, 'one notification despite two runs');
  });

  test('suspension on expiry happens only when the document type policy says so', async () => {
    const { stationId } = await approvedStation();
    const code = `strict_${Math.floor(Math.random() * 1e9)}`;
    const type = await one(
      `insert into public.document_types (code, name, scope, is_required, requires_expiry_date, expiry_suspends_station)
       values ($1, 'Strict licence', 'station', false, true, true) returning id`, [code]);
    const business = await one(`select business_id from public.stations where id = $1`, [stationId]);
    await sql(
      `insert into public.station_documents (business_id, station_id, document_type_id, storage_path, file_name, mime_type,
                                             size_bytes, status, expires_on, uploaded_by)
       select $1, $2, $3, $1 || '/' || $2 || '/strict.pdf', 'strict.pdf', 'application/pdf', 100, 'approved', current_date - 1, owner_id
         from public.businesses where id = $1`, [business.business_id, stationId, type.id]);
    const res = await rpc('service', 'run_compliance_jobs');
    assert.ok(res.stations_suspended >= 1);
    assert.equal((await one(`select status from public.stations where id = $1`, [stationId])).status, 'suspended');
    await sql(`update public.document_types set is_active = false where id = $1`, [type.id]);
  });

  test('expiry reminders are sent once per configured threshold', async () => {
    const { owner, stationId } = await approvedStation();
    const doc = await one(
      `update public.station_documents set expires_on = current_date + 7
        where station_id = $1 and status = 'approved' returning id`, [stationId]);
    await rpc('service', 'run_compliance_jobs');
    await rpc('service', 'run_compliance_jobs');
    const notes = await as(owner.id, (q) => q(`select count(*)::int n from public.notifications where type = 'document.expiring' and data->>'document_id' = $1`, [doc.id]));
    assert.equal(notes[0].n, 1);
  });
});
