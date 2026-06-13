// API_BASE resolution:
//  - VITE_API_URL unset        -> local dev default (separate Vite + API ports)
//  - VITE_API_URL === ""        -> same-origin: the API serves this web build,
//                                  so use relative paths ("/auth/login" etc.)
//  - scheme-less host           -> prepend https:// (Render fromService `host`)
//  - full URL                   -> use as-is
const raw: unknown = import.meta.env.VITE_API_URL;
export const API_BASE =
  raw === undefined
    ? "http://localhost:10000"
    : raw === ""
      ? ""
      : /^https?:\/\//.test(raw as string)
        ? (raw as string)
        : `https://${raw}`;

const TOKEN_KEY = "whnow_token";
export const getToken = () => localStorage.getItem(TOKEN_KEY);
export const setToken = (t: string) => localStorage.setItem(TOKEN_KEY, t);
export const clearToken = () => localStorage.removeItem(TOKEN_KEY);

export async function api<T = any>(path: string, options: RequestInit = {}): Promise<T> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(options.headers as Record<string, string>),
  };
  const token = getToken();
  if (token) headers.Authorization = `Bearer ${token}`;

  const res = await fetch(`${API_BASE}${path}`, { ...options, headers });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.error ?? `Request failed (${res.status})`);
  }
  return res.json();
}
