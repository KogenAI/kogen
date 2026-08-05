// roles.ts — single source of truth for the 7 concrete cycle roles and their
// per-role codegen-log kind grants + reader grants. Mirrors what each role is
// taught in shared/rules/_core/session-log.md:37 (the loop authors
// files_to_touch; developer authors files_modified) and the
// reviewer's sanctioned gate-result.json .verdict read (shared/rules/roles/reviewer.md).
//
// This is the ONE place role-baking is decided — src/tools.ts generates
// log_section_<role>/log_append_<role> tool pairs from this list; no caller
// ever passes a role as an argument (see AGENTS.md pitch "role must be
// explicit — env-derivation removed" claim).

export type MarkerKind =
  | "learned"
  | "no_learning"
  | "died"
  | "verdict"
  | "files_to_touch"
  | "files_modified";

export interface RoleSpec {
  /** codegen-log role string, exact match to the installed agent name. */
  role: string;
  /** Marker kinds this role is allowed to append beyond body/learned/no_learning/died. */
  extraKinds: MarkerKind[];
  /** Whether this role is granted the read-only gate_status/log_read tools. */
  readers: boolean;
}

// Every concrete role gets: body (via section), learned, no_learning, died —
// those are universal (session-log.md:34-35). extraKinds adds the
// role-specific typed markers. readers grants gate_status/log_read.
export const ROLES: RoleSpec[] = [
  {
    role: "developer-phoenix-backend",
    extraKinds: ["files_modified"],
    readers: false,
  },
  {
    role: "developer-phoenix-frontend",
    extraKinds: ["files_modified"],
    readers: false,
  },
  { role: "developer-static", extraKinds: ["files_modified"], readers: false },
  { role: "reviewer-phoenix", extraKinds: [], readers: true },
  { role: "reviewer-static", extraKinds: [], readers: true },
  { role: "context-curator", extraKinds: [], readers: true },
  { role: "committer", extraKinds: [], readers: true },
];

export function findRole(role: string): RoleSpec | undefined {
  return ROLES.find((r) => r.role === role);
}

/** Tool name for a role's `section` writer (body + optional learned in one call). */
export function sectionToolName(role: string): string {
  return `log_section_${role.replace(/-/g, "_")}`;
}

/** Tool name for a role's `append` writer (marker events). */
export function appendToolName(role: string): string {
  return `log_append_${role.replace(/-/g, "_")}`;
}
