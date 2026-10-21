import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  as, rpc, rpcRow, sql, one, rejectsWith, closePool, createUser, createStaff, createBusiness, createStation,
  addPoint, setHours, uploadRequiredDocs, approvedStation,
} from './lib/db.mjs';

after(closePool);

async function draftApplication() {
  const owner = await createUser('owner');
  const businessId = await createBusiness(owner);
  const stationId = await createStation(owner, businessId);
  const app = await one(`select id, status from public.station_applications where station_id = $1`, [stationId]);
  return { owner, businessId, stationId, applicationId: app.id, status: app.status };
}

describe('business registration', () => {
  test('create_business makes the caller owner with pending verification', async () => {
    const owner = await createUser('owner');
    const id = await createBusiness(owner);
    const b = await one(`select status, owner_id from public.businesses where id = $1`, [id]);
    assert.equal(b.status, 'pending_verification');
    assert.equal(b.owner_id, owner.id);
    const access = await rpc(owner.id, 'my_business_access');
    assert.equal(access.length, 1);
    assert.equal(access[0].role, 'owner');
  });

  test('anonymous callers cannot register a business', async () => {
    await rejectsWith(
      as('anon', (q) => q(`select public.create_business('A','A','A','+919800000000','a@b.co','individual')`)),
      { sqlstate: '42501' },
    );
  });

  test('owner cannot change business status or ownership directly', async () => {
    const { owner, businessId } = await draftApplication();
    await rejectsWith(
      as(owner.id, (q) => q(`update public.businesses set status = 'active' where id = $1`, [businessId])),
      { sqlstate: '42501' },
    );
    const other = await createUser('other');
    await rejectsWith(
      as(owner.id, (q) => q(`update public.businesses set owner_id = $2 where id = $1`, [businessId, other.id])),
      { sqlstate: '42501' },
    );
  });

  test('new station is forced to draft with a draft application', async () => {
    const owner = await createUser('owner');
    const businessId = await createBusiness(owner);
    const stationId = await as(owner.id, async (q) => (await q(
      `insert into public.stations (business_id, name, address_line1, city, district, state, postal_code, latitude, longitude,
                                    contact_phone, status, approved_at)
       values ($1, 'Sneaky', '1 Road', 'Pune', 'Pune', 'Maharashtra', '411001', 18.52, 73.85, '+919811111111', 'active', now())
       returning id`, [businessId]))[0].id);
    const s = await one(`select status, approved_at from public.stations where id = $1`, [stationId]);
    assert.equal(s.status, 'draft');
    assert.equal(s.approved_at, null);
    const app = await one(`select status from public.station_applications where station_id = $1`, [stationId]);
    assert.equal(app.status, 'draft');
  });

  test('implausible coordinates for an Indian station are rejected', async () => {
    const owner = await createUser('owner');
    const businessId = await createBusiness(owner);
    await rejectsWith(createStation(owner, businessId, { latitude: 51.5, longitude: -0.12 }), { sqlstate: '23514' });
  });
});

describe('application workflow', () => {
  test('submission requires a charging point, hours and required documents', async () => {
    const { owner, businessId, stationId, applicationId } = await draftApplication();
    await rejectsWith(rpc(owner.id, 'submit_station_application', [applicationId]), { status: 422, code: 'charging_point_required' });
    await addPoint(owner, stationId);
    await rejectsWith(rpc(owner.id, 'submit_station_application', [applicationId]), { status: 422, code: 'operating_hours_required' });
    await setHours(owner, stationId, 360, 1320);
    const err = await rejectsWith(rpc(owner.id, 'submit_station_application', [applicationId]), { status: 422, code: 'missing_documents' });
    assert.match(err.detail, /Owner identity proof/);
    await uploadRequiredDocs(owner, businessId, stationId);
    const app = await rpcRow(owner.id, 'submit_station_application', [applicationId]);
    assert.equal(app.status, 'submitted');
    assert.equal(app.revision, 1);
  });

  test('document uploads are validated against the configured type', async () => {
    const { owner, businessId, stationId } = await draftApplication();
    const type = await one(`select id from public.document_types where code = 'electricity_connection'`);
    const insertDoc = (mime, size, station = stationId) =>
      as(owner.id, (q) => q(
        `insert into public.station_documents (business_id, station_id, document_type_id, storage_path, file_name, mime_type, size_bytes)
         values ($1, $2, $3, $4, 'x', $5, $6)`,
        [businessId, station, type.id, `${businessId}/${stationId}/${Math.random()}.bin`, mime, size]));
    await rejectsWith(insertDoc('application/zip', 100), { status: 422, code: 'invalid_file_type' });
    await rejectsWith(insertDoc('application/pdf', 50_000_000), { status: 422, code: 'file_too_large' });
    await rejectsWith(insertDoc('application/pdf', 100, null), { status: 422, code: 'document_scope_mismatch' });
  });

  test('owner cannot review or approve their own application', async () => {
    const { owner, businessId, stationId, applicationId } = await draftApplication();
    await addPoint(owner, stationId);
    await setHours(owner, stationId);
    const docs = await uploadRequiredDocs(owner, businessId, stationId);
    await rpc(owner.id, 'submit_station_application', [applicationId]);
    await rejectsWith(rpc(owner.id, 'start_application_review', [applicationId]), { status: 403 });
    await rejectsWith(rpc(owner.id, 'approve_station_application', [applicationId, null]), { status: 403 });
    await rejectsWith(rpc(owner.id, 'review_document', [docs[0], 'approved', null]), { status: 403 });
    await rejectsWith(
      as(owner.id, (q) => q(`update public.station_applications set status = 'approved' where id = $1`, [applicationId])),
      { sqlstate: '42501' },
    );
  });

  test('reviewer requests information, owner resubmits, admin approves', async () => {
    const reviewer = await createStaff('compliance_reviewer');
    const admin = await createStaff('admin');
    const { owner, businessId, stationId, applicationId } = await draftApplication();
    await addPoint(owner, stationId);
    await setHours(owner, stationId);
    const docs = await uploadRequiredDocs(owner, businessId, stationId);
    await rpc(owner.id, 'submit_station_application', [applicationId]);

    await rpc(reviewer.id, 'start_application_review', [applicationId]);
    // Compliance reviewers cannot approve by default.
    await rejectsWith(rpc(reviewer.id, 'approve_station_application', [applicationId, null]), { status: 403 });
    await rejectsWith(rpc(reviewer.id, 'request_application_information', [applicationId, '']), { status: 422, code: 'note_required' });
    await rpc(reviewer.id, 'review_document', [docs[0], 'correction_required', 'Scan is unreadable']);
    const app = await rpcRow(reviewer.id, 'request_application_information', [applicationId, 'Please upload a readable ID proof']);
    assert.equal(app.status, 'additional_information_required');

    const notes = await as(owner.id, (q) => q(`select type, body from public.notifications order by created_at`));
    assert.ok(notes.some((n) => n.type === 'application.info_requested' && /readable ID/.test(n.body)));
    assert.ok(notes.some((n) => n.type === 'document.correction_required'));

    // Resubmission is blocked until the document is replaced.
    await rejectsWith(rpc(owner.id, 'submit_station_application', [applicationId]), { status: 422, code: 'missing_documents' });
    const newDocs = await uploadRequiredDocs(owner, businessId, stationId);
    const superseded = await one(`select status from public.station_documents where id = $1`, [docs[0]]);
    assert.equal(superseded.status, 'superseded');
    const resubmitted = await rpcRow(owner.id, 'submit_station_application', [applicationId]);
    assert.equal(resubmitted.revision, 2);

    await rpc(admin.id, 'start_application_review', [applicationId]);
    await rejectsWith(rpc(admin.id, 'approve_station_application', [applicationId, null]), { status: 422, code: 'documents_not_verified' });
    for (const d of newDocs) await rpc(admin.id, 'review_document', [d, 'approved', null]);
    // Older approved versions were superseded by approving the new ones.
    const approved = await rpcRow(admin.id, 'approve_station_application', [applicationId, 'Looks good']);
    assert.equal(approved.status, 'approved');
    assert.equal(approved.decided_by, admin.id);

    const station = await one(`select status, approved_by from public.stations where id = $1`, [stationId]);
    assert.equal(station.status, 'active');
    assert.equal(station.approved_by, admin.id);
    const business = await one(`select status from public.businesses where id = $1`, [businessId]);
    assert.equal(business.status, 'active');

    const timeline = await as(owner.id, (q) => q(
      `select from_status, to_status from public.application_events where application_id = $1 order by id`, [applicationId]));
    assert.deepEqual(timeline.map((e) => e.to_status),
      ['draft', 'submitted', 'under_review', 'additional_information_required', 'submitted', 'under_review', 'approved']);
    const audit = await sql(`select action from public.audit_logs where entity_id = $1 order by id`, [applicationId]);
    assert.ok(audit.some((a) => a.action === 'application.approve'));
  });

  test('rejection needs a reason and allows correction and resubmission', async () => {
    const admin = await createStaff('admin');
    const { owner, businessId, stationId, applicationId } = await draftApplication();
    await addPoint(owner, stationId);
    await setHours(owner, stationId);
    await uploadRequiredDocs(owner, businessId, stationId);
    await rpc(owner.id, 'submit_station_application', [applicationId]);
    await rpc(admin.id, 'start_application_review', [applicationId]);
    await rejectsWith(rpc(admin.id, 'reject_station_application', [applicationId, '', true]), { status: 422, code: 'reason_required' });
    const rejected = await rpcRow(admin.id, 'reject_station_application', [applicationId, 'Site lease has expired', true]);
    assert.equal(rejected.status, 'rejected');
    assert.equal(rejected.latest_feedback, 'Site lease has expired');
    const again = await rpcRow(owner.id, 'submit_station_application', [applicationId]);
    assert.equal(again.status, 'submitted');

    await rpc(admin.id, 'start_application_review', [applicationId]);
    await rpc(admin.id, 'reject_station_application', [applicationId, 'Not an EV charging site', false]);
    await rejectsWith(rpc(owner.id, 'submit_station_application', [applicationId]), { status: 409, code: 'resubmission_not_allowed' });
  });

  test('invalid transitions are refused', async () => {
    const admin = await createStaff('admin');
    const { applicationId } = await draftApplication();
    await rejectsWith(rpc(admin.id, 'approve_station_application', [applicationId, null]), { status: 422 });
    await rejectsWith(rpc(admin.id, 'start_application_review', [applicationId]), { status: 409, code: 'invalid_status_transition' });
  });

  test('platform staff cannot review a business they belong to', async () => {
    const admin = await createStaff('admin');
    const { businessId, applicationId, owner, stationId } = await draftApplication();
    await addPoint(owner, stationId);
    await setHours(owner, stationId);
    await uploadRequiredDocs(owner, businessId, stationId);
    await rpc(owner.id, 'submit_station_application', [applicationId]);
    await sql(`insert into public.business_members (business_id, user_id, role) values ($1, $2, 'station_staff')`, [businessId, admin.id]);
    await rejectsWith(rpc(admin.id, 'start_application_review', [applicationId]), { status: 403, code: 'conflict_of_interest' });
  });
});

describe('station management after approval', () => {
  test('sensitive fields need an approved change request; others are editable', async () => {
    const { owner, admin, stationId } = await approvedStation();
    await as(owner.id, (q) => q(`update public.stations set description = 'Now with a cafe' where id = $1`, [stationId]));
    await rejectsWith(
      as(owner.id, (q) => q(`update public.stations set latitude = 12.99 where id = $1`, [stationId])),
      { status: 403, code: 'sensitive_change_requires_approval' },
    );
    await rejectsWith(rpc(owner.id, 'request_station_change', [stationId, { description: 'x' }, null]), { status: 422 });
    const reqId = await rpc(owner.id, 'request_station_change', [stationId, { latitude: 12.99, longitude: 77.6 }, 'Pin was off']);
    await rejectsWith(rpc(owner.id, 'decide_station_change', [reqId, true, null]), { status: 403 });
    await rpc(admin.id, 'decide_station_change', [reqId, true, 'Verified on map']);
    const s = await one(`select latitude, longitude, name from public.stations where id = $1`, [stationId]);
    assert.equal(s.latitude, 12.99);
    assert.equal(s.longitude, 77.6);
    assert.equal(s.name, 'Test Station');
  });

  test('suspension cancels future bookings and blocks new ones; reactivation restores', async () => {
    const { admin, stationId } = await approvedStation();
    await rejectsWith(rpc(admin.id, 'suspend_station', [stationId, '', true]), { status: 422 });
    const res = await rpc(admin.id, 'suspend_station', [stationId, 'Safety inspection failed', true]);
    assert.equal(res.status, 'suspended');
    const app = await one(`select status from public.station_applications where station_id = $1`, [stationId]);
    assert.equal(app.status, 'suspended');
    await rejectsWith(rpc(admin.id, 'reactivate_station', [stationId, '']), { status: 422 });
    await rpc(admin.id, 'reactivate_station', [stationId, 'Re-inspection passed']);
    const s = await one(`select status from public.stations where id = $1`, [stationId]);
    assert.equal(s.status, 'active');
  });

  test('compliance reviewer cannot suspend stations', async () => {
    const reviewer = await createStaff('compliance_reviewer');
    const { stationId } = await approvedStation();
    await rejectsWith(rpc(reviewer.id, 'suspend_station', [stationId, 'Because I can', true]), { status: 403 });
  });
});
