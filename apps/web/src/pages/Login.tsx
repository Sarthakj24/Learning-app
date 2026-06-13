import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { api, setToken } from "../api";

export default function Login() {
  const nav = useNavigate();
  const [workspace, setWorkspace] = useState("acme");
  const [email, setEmail] = useState("admin@acme.in");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit() {
    setBusy(true);
    setError("");
    try {
      const { token } = await api("/auth/login", {
        method: "POST",
        body: JSON.stringify({ workspace, email, password }),
      });
      setToken(token);
      nav("/");
    } catch (e: any) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="auth">
      <div className="auth__card">
        <div className="brand">
          <span className="brand__mark">W</span>
          <div>
            <div className="brand__name">WH Now Learn</div>
            <div className="brand__sub">Warehouse training &amp; competency</div>
          </div>
        </div>
        <h1>Sign in</h1>
        <label>Workspace</label>
        <input value={workspace} onChange={(e) => setWorkspace(e.target.value)} />
        <label>Email or staff ID</label>
        <input value={email} onChange={(e) => setEmail(e.target.value)} />
        <label>Password</label>
        <input type="password" value={password} onChange={(e) => setPassword(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && submit()} />
        {error && <div className="error">{error}</div>}
        <button className="btn" disabled={busy} onClick={submit}>
          {busy ? "Signing in…" : "Sign in"}
        </button>
        <p className="hint">Seeded demo: workspace <b>acme</b>, email <b>admin@acme.in</b> (password set during seeding).</p>
      </div>
    </div>
  );
}
