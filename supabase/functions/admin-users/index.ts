/*
  admin-users — owner-only account management for the Powerant Portal.

  Actions (POST JSON body):
    { action: 'create',         full_name, username, password }
    { action: 'reset_password', user_id, password }
    { action: 'set_active',     user_id, active }

  Why this runs on the server: creating logins and resetting passwords need
  Supabase's secret key, which must never be in a browser.

  Security:
    - The caller's login token is verified, and they must be an active owner.
    - Database changes to profiles are made AS THE OWNER (with their token),
      so row-level security, the last-owner guard and the activity log all
      apply exactly as if the owner did it in the app.
    - Only Auth admin calls (create user, set password, ban) use the secret key.

  Deploy from the powerant-db folder:
    npx supabase functions deploy admin-users --no-verify-jwt
  (--no-verify-jwt because the token is verified in code below, which works
  with both the new and legacy Supabase API keys.)
*/
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

const STAFF_EMAIL_DOMAIN = 'staff.powerant.local';
const USERNAME_PATTERN = /^[a-z0-9._-]{3,32}$/;
const MIN_PASSWORD_LENGTH = 8;
const BAN_FOREVER = '876000h'; // ~100 years

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

/** New API keys arrive as a JSON dictionary; legacy keys as a single value. */
function pickKey(dictionaryVar: string, legacyVar: string): string {
  const dict = Deno.env.get(dictionaryVar);
  if (dict) {
    try {
      const parsed = JSON.parse(dict) as Record<string, string>;
      const key = parsed['default'] ?? Object.values(parsed)[0];
      if (key) return key;
    } catch {
      // fall through to legacy
    }
  }
  const legacy = Deno.env.get(legacyVar);
  if (legacy) return legacy;
  throw new HttpError(500, `Server is missing ${dictionaryVar} / ${legacyVar}.`);
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== 'string' || !value.trim()) throw new HttpError(400, `Missing ${field}.`);
  return value;
}

function checkPassword(password: string) {
  if (password.length < MIN_PASSWORD_LENGTH) {
    throw new HttpError(400, `Password must be at least ${MIN_PASSWORD_LENGTH} characters.`);
  }
}

async function logActivity(
  admin: SupabaseClient,
  caller: { id: string; name: string },
  action: string,
  targetId: string,
  summary: string,
) {
  const { error } = await admin.schema('portal').from('activity_log').insert({
    user_id: caller.id,
    user_name: caller.name,
    module: 'portal',
    action,
    entity_type: 'portal.profiles',
    entity_id: targetId,
    summary,
    details: {},
  });
  if (error) console.error('activity log insert failed', error);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed.' }, 405);

  try {
    const url = Deno.env.get('SUPABASE_URL');
    if (!url) throw new HttpError(500, 'Server is missing SUPABASE_URL.');
    const secretKey = pickKey('SUPABASE_SECRET_KEYS', 'SUPABASE_SERVICE_ROLE_KEY');
    const publishableKey = pickKey('SUPABASE_PUBLISHABLE_KEYS', 'SUPABASE_ANON_KEY');

    // ---- 1. Who is calling?
    const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    if (!token) throw new HttpError(401, 'Not signed in.');

    const admin = createClient(url, secretKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: userData, error: userError } = await admin.auth.getUser(token);
    if (userError || !userData.user) throw new HttpError(401, 'Your session has expired. Sign in again.');
    const callerId = userData.user.id;

    // Client acting AS the owner: RLS, guards and audit triggers apply.
    const asCaller = createClient(url, publishableKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // ---- 2. Must be an active owner
    const { data: callerProfile } = await admin
      .schema('portal')
      .from('profiles')
      .select('full_name, username, role, active')
      .eq('user_id', callerId)
      .maybeSingle();
    if (!callerProfile || callerProfile.role !== 'owner' || !callerProfile.active) {
      throw new HttpError(403, 'Only the owner can manage team accounts.');
    }
    const caller = { id: callerId, name: callerProfile.full_name || callerProfile.username || 'Owner' };

    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;

    // ---- 3. Actions
    switch (body.action) {
      case 'create': {
        const fullName = requireString(body.full_name, 'name').trim();
        const username = requireString(body.username, 'username').trim().toLowerCase();
        const password = requireString(body.password, 'password');
        if (!USERNAME_PATTERN.test(username)) {
          throw new HttpError(400, 'Username must be 3–32 characters: lowercase letters, numbers, dot, dash or underscore.');
        }
        checkPassword(password);

        const { data: taken } = await admin
          .schema('portal')
          .from('profiles')
          .select('user_id')
          .eq('username', username)
          .maybeSingle();
        if (taken) throw new HttpError(409, `The username "${username}" is already taken.`);

        const { data: created, error: createError } = await admin.auth.admin.createUser({
          email: `${username}@${STAFF_EMAIL_DOMAIN}`,
          password,
          email_confirm: true, // no email is ever sent; the address is internal
          user_metadata: { full_name: fullName, username },
        });
        if (createError || !created.user) {
          const msg = createError?.message ?? '';
          if (/already/i.test(msg)) throw new HttpError(409, `The username "${username}" is already taken.`);
          throw new HttpError(400, msg || 'Could not create the login.');
        }
        const newId = created.user.id;

        // The database trigger created the profile as inactive; activate it as the owner.
        const { error: activateError } = await asCaller
          .schema('portal')
          .from('profiles')
          .update({ active: true })
          .eq('user_id', newId);
        if (activateError) {
          await admin.auth.admin.deleteUser(newId); // don't leave a half-made account
          throw new HttpError(500, `Could not activate the new login: ${activateError.message}`);
        }

        await logActivity(admin, caller, 'user_created', newId, `Added employee ${fullName} (${username})`);
        return json({ ok: true, user_id: newId });
      }

      case 'reset_password': {
        const userId = requireString(body.user_id, 'user');
        const password = requireString(body.password, 'password');
        checkPassword(password);

        const { data: target } = await admin
          .schema('portal')
          .from('profiles')
          .select('full_name, username')
          .eq('user_id', userId)
          .maybeSingle();
        if (!target) throw new HttpError(404, 'That person was not found.');

        const { error } = await admin.auth.admin.updateUserById(userId, { password });
        if (error) throw new HttpError(400, error.message);

        await logActivity(
          admin,
          caller,
          'password_reset',
          userId,
          `Reset password for ${target.full_name || target.username}`,
        );
        return json({ ok: true });
      }

      case 'set_active': {
        const userId = requireString(body.user_id, 'user');
        if (typeof body.active !== 'boolean') throw new HttpError(400, 'Missing active.');
        if (userId === callerId) throw new HttpError(400, 'You cannot deactivate your own account.');

        // 1) Database first, as the owner: RLS + last-owner guard + activity log.
        const { data: updated, error: dbError } = await asCaller
          .schema('portal')
          .from('profiles')
          .update({ active: body.active })
          .eq('user_id', userId)
          .select('user_id');
        if (dbError) throw new HttpError(400, dbError.message);
        if (!updated?.length) throw new HttpError(404, 'That person was not found.');

        // 2) Then block or unblock the login itself.
        const { error: banError } = await admin.auth.admin.updateUserById(userId, {
          ban_duration: body.active ? 'none' : BAN_FOREVER,
        });
        if (banError) {
          // Data access is already off/on via the profile; report the partial result.
          throw new HttpError(500, `Status saved, but updating the login failed: ${banError.message}`);
        }
        return json({ ok: true });
      }

      default:
        throw new HttpError(400, 'Unknown action.');
    }
  } catch (err) {
    if (err instanceof HttpError) return json({ error: err.message }, err.status);
    console.error(err);
    return json({ error: 'Unexpected server error.' }, 500);
  }
});
