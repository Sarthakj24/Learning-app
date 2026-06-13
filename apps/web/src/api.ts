const raw = import.meta.env.VITE_API_URL ?? "http://localhost:10000";
// Render's fromService `host` is scheme-less (e.g. whnow-learn-api.onrender.com);
// prepend https:// when no scheme is present.
export const API_BASE = /^https?:\/\//.test(raw) ? raw : `https://${raw}`;

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
