import { createClient } from "npm:@supabase/supabase-js@2";
import { createRegistrationHandler } from "./handler.mjs";
Deno.serve(createRegistrationHandler({
  createClient,
  url: Deno.env.get("SUPABASE_URL")!,
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  apiKey: Deno.env.get("SUPABASE_ANON_KEY")!
}));
