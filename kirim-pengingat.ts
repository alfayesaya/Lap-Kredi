// Supabase Edge Function: supabase/functions/kirim-pengingat/index.ts  (salin isi file ini ke sana)
// Mengirim notifikasi push ke HP kreditur: H-3, H-1, hari H, dan tiap hari bila terlambat.
//
// Langkah:
//  1. npx web-push generate-vapid-keys        -> dapat public & private key
//  2. Tempel public key ke index.html pada  var VAPID_PUBLIC="..."
//  3. supabase secrets set VAPID_PUBLIC=... VAPID_PRIVATE=... VAPID_SUBJECT=mailto:emailmu@contoh.com CRON_SECRET=isi-rahasia-bebas
//  4. supabase functions deploy kirim-pengingat --no-verify-jwt
//  5. Jalankan bagian "6) cron" di setup-v2.sql (hapus tanda komentar, isi PROJECT_REF & RAHASIA_CRON)
//  6. Upload index.html + sw.js + manifest.json ke hosting HTTPS yang sama (satu folder)
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT")!, Deno.env.get("VAPID_PUBLIC")!, Deno.env.get("VAPID_PRIVATE")!);
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const rp = (n: number) => "Rp" + Math.round(n).toLocaleString("id-ID");

function dueDate(tgl: string, n: number) {
  const [y, m, d] = tgl.split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1 + n, 1));
  const last = new Date(Date.UTC(t.getUTCFullYear(), t.getUTCMonth() + 1, 0)).getUTCDate();
  t.setUTCDate(Math.min(d, last));
  return t;
}

Deno.serve(async (req) => {
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) return new Response("forbidden", { status: 403 });
  const w = new Date(Date.now() + 7 * 3600e3); // WIB
  const today = Date.UTC(w.getUTCFullYear(), w.getUTCMonth(), w.getUTCDate());
  const { data: kr, error } = await sb.from("kredit")
    .select("id,user_id,ket,tgl,angs,bulan,sisa,tanda").not("user_id", "is", null).gt("sisa", 0);
  if (error) return new Response(error.message, { status: 500 });
  let sent = 0;
  for (const k of kr ?? []) {
    if (k.tanda || !k.tgl) continue;
    const diff = Math.round((dueDate(k.tgl, k.bulan - k.sisa + 1).getTime() - today) / 864e5);
    if (!(diff === 3 || diff === 1 || diff === 0 || diff < 0)) continue;
    const { data: subs } = await sb.from("push_subs").select("endpoint,sub").eq("user_id", k.user_id);
    const body = `${k.ket || "Kredit"}: angsuran ke-${k.bulan - k.sisa + 1}/${k.bulan} ${rp(k.angs)} ` +
      (diff < 0 ? `terlambat ${-diff} hari` : diff === 0 ? "jatuh tempo hari ini" : `jatuh tempo ${diff} hari lagi`) +
      ". Setelah bayar, kirim foto bukti di aplikasi.";
    for (const s of subs ?? []) {
      try { await webpush.sendNotification(s.sub, JSON.stringify({ title: "Pengingat angsuran", body, tag: "kredit-" + k.id })); sent++; }
      catch (e) { const c = (e as any).statusCode; if (c === 404 || c === 410) await sb.from("push_subs").delete().eq("endpoint", s.endpoint); }
    }
  }
  return new Response(JSON.stringify({ sent }), { headers: { "Content-Type": "application/json" } });
});
