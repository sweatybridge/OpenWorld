// Credential persistence for the mobile client.
//
// The web app stores a bearer token in localStorage and hits a relative /api
// path. A phone can't reach the dev box's 127.0.0.1, so the mobile client needs
// a configurable server BASE URL (AsyncStorage — not secret) plus the bearer
// token (expo-secure-store — encrypted keychain/keystore). Both are loaded once
// at startup into module-level state so the synchronous apiFetch can read them.

import AsyncStorage from "@react-native-async-storage/async-storage";
import * as SecureStore from "expo-secure-store";

const BASE_URL_KEY = "attobot_dashboard_base_url";
const TOKEN_KEY = "attobot_dashboard_token";

let _baseUrl = "";
let _token = "";

export function baseUrl(): string {
  return _baseUrl;
}

export function token(): string {
  return _token;
}

export function hasBaseUrl(): boolean {
  return _baseUrl.length > 0;
}

// Trim trailing slashes so `base + "/api/..."` never doubles up.
function normalizeBase(raw: string): string {
  return raw.trim().replace(/\/+$/, "");
}

export async function loadCredentials(): Promise<void> {
  const base = await AsyncStorage.getItem(BASE_URL_KEY);
  _baseUrl = base ? normalizeBase(base) : "";
  try {
    _token = (await SecureStore.getItemAsync(TOKEN_KEY)) ?? "";
  } catch {
    // SecureStore can throw in emulators / when the device isn't unlocked.
    _token = "";
  }
}

export interface SavedCredentials {
  base: string;
}

export async function saveCredentials(
  rawBase: string,
  tok: string,
): Promise<SavedCredentials> {
  const base = normalizeBase(rawBase);
  _baseUrl = base;
  _token = tok;
  await AsyncStorage.setItem(BASE_URL_KEY, base);
  if (tok) {
    await SecureStore.setItemAsync(TOKEN_KEY, tok);
  } else {
    try {
      await SecureStore.deleteItemAsync(TOKEN_KEY);
    } catch {
      /* ignore — nothing to delete */
    }
  }
  return { base };
}

export async function clearToken(): Promise<void> {
  _token = "";
  try {
    await SecureStore.deleteItemAsync(TOKEN_KEY);
  } catch {
    /* ignore */
  }
}
