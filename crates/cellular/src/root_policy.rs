//! Pure root-policy contract for generation-bound Cellular Egress.
//!
//! This module owns policy identity, exact MISH rule shape, collision detection and verification.
//! It performs no shell I/O, owns no timers and imports no Android/runtime mechanism.

use std::collections::{HashMap, HashSet};

pub const IPV4_RULE_SHOW: &str = "ip -4 rule show";
pub const IPV6_RULE_SHOW: &str = "ip -6 rule show";
pub const IPTABLES: &str = "iptables";
pub const IP6TABLES: &str = "ip6tables";
pub const MAX_RECONCILE_PASSES: usize = 8;

const RELEASE_MISH_CHAIN: &str = "MISH_EGRESS_V1";
const DEBUG_MISH_CHAIN: &str = "MISH_DEBUG_EGRESS_V1";
const IPV4_FULL_MASK: u64 = 0xffff_ffff;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RootPolicyNamespace {
    Release,
    Debug,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PolicyIdentity {
    mark_hex: &'static str,
    mark_value: u64,
    lookup_priority: u32,
    guard_priority: u32,
}

impl PolicyIdentity {
    pub const fn mark_hex(self) -> &'static str {
        self.mark_hex
    }

    pub const fn mark_value(self) -> u64 {
        self.mark_value
    }

    pub const fn lookup_priority(self) -> u32 {
        self.lookup_priority
    }

    pub const fn guard_priority(self) -> u32 {
        self.guard_priority
    }
}

const RELEASE_POLICY_CANDIDATES: [PolicyIdentity; 4] = [
    PolicyIdentity {
        mark_hex: "0x200000",
        mark_value: 0x20_0000,
        lookup_priority: 9500,
        guard_priority: 9501,
    },
    PolicyIdentity {
        mark_hex: "0x400000",
        mark_value: 0x40_0000,
        lookup_priority: 9520,
        guard_priority: 9521,
    },
    PolicyIdentity {
        mark_hex: "0x800000",
        mark_value: 0x80_0000,
        lookup_priority: 9540,
        guard_priority: 9541,
    },
    PolicyIdentity {
        mark_hex: "0x1000000",
        mark_value: 0x100_0000,
        lookup_priority: 9560,
        guard_priority: 9561,
    },
];

const DEBUG_POLICY_CANDIDATES: [PolicyIdentity; 4] = [
    PolicyIdentity {
        mark_hex: "0x2000000",
        mark_value: 0x200_0000,
        lookup_priority: 9580,
        guard_priority: 9581,
    },
    PolicyIdentity {
        mark_hex: "0x4000000",
        mark_value: 0x400_0000,
        lookup_priority: 9600,
        guard_priority: 9601,
    },
    PolicyIdentity {
        mark_hex: "0x8000000",
        mark_value: 0x800_0000,
        lookup_priority: 9620,
        guard_priority: 9621,
    },
    PolicyIdentity {
        mark_hex: "0x10000000",
        mark_value: 0x1000_0000,
        lookup_priority: 9640,
        guard_priority: 9641,
    },
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RootPolicySnapshot {
    pub ipv4_rules: Vec<String>,
    pub ipv6_rules: Vec<String>,
    pub ipv4_mangle: Vec<String>,
    pub ipv6_mangle: Vec<String>,
}

impl RootPolicySnapshot {
    pub fn new(
        ipv4_rules: Vec<String>,
        ipv6_rules: Vec<String>,
        ipv4_mangle: Vec<String>,
        ipv6_mangle: Vec<String>,
    ) -> Self {
        Self {
            ipv4_rules,
            ipv6_rules,
            ipv4_mangle,
            ipv6_mangle,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PolicyIdentityResolution {
    Selected(PolicyIdentity),
    Collision,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MangleAuditResult {
    Clean,
    Collision,
    Ambiguous,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MangleFamilyState {
    Missing,
    DetachedExact,
    DetachedMismatch,
    AttachedExact,
    AttachedDuplicateExact,
    InvalidReferenced,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RootPolicyStructuralFailure {
    IdentityUnavailable,
    ReservedPolicyCollision,
    MangleMismatch,
    GuardMismatch,
    LookupStillPresent,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RootPolicyContract {
    product_uid: u32,
    namespace: RootPolicyNamespace,
    active_identity: Option<PolicyIdentity>,
}

impl RootPolicyContract {
    pub fn new(product_uid: u32, namespace: RootPolicyNamespace) -> Option<Self> {
        if product_uid == 0 {
            return None;
        }
        Some(Self {
            product_uid,
            namespace,
            active_identity: None,
        })
    }

    pub const fn product_uid(&self) -> u32 {
        self.product_uid
    }

    pub const fn active_identity(&self) -> Option<PolicyIdentity> {
        self.active_identity
    }

    pub fn clear_active_identity(&mut self) {
        self.active_identity = None;
    }

    pub const fn chain_name(&self) -> &'static str {
        match self.namespace {
            RootPolicyNamespace::Release => RELEASE_MISH_CHAIN,
            RootPolicyNamespace::Debug => DEBUG_MISH_CHAIN,
        }
    }

    pub fn candidates(&self) -> &'static [PolicyIdentity] {
        match self.namespace {
            RootPolicyNamespace::Release => &RELEASE_POLICY_CANDIDATES,
            RootPolicyNamespace::Debug => &DEBUG_POLICY_CANDIDATES,
        }
    }

    pub fn legacy_mark_hex(&self) -> &'static str {
        self.candidates()[0].mark_hex()
    }

    pub fn resolve_identity(
        &mut self,
        snapshot: &RootPolicySnapshot,
    ) -> PolicyIdentityResolution {
        let chain = self.chain_name();
        let ipv4_chain_exists = snapshot.ipv4_mangle.iter().any(|line| line == &format!("-N {chain}"));
        let ipv6_chain_exists = snapshot.ipv6_mangle.iter().any(|line| line == &format!("-N {chain}"));
        let ipv4_chain = chain_lines(&snapshot.ipv4_mangle, chain);
        let ipv6_chain = chain_lines(&snapshot.ipv6_mangle, chain);

        if (!ipv4_chain_exists && self.output_jump_count(&snapshot.ipv4_mangle) != 0)
            || (!ipv6_chain_exists && self.output_jump_count(&snapshot.ipv6_mangle) != 0)
            || (self.output_jump_count(&snapshot.ipv4_mangle) != 0 && ipv4_chain.is_empty())
            || (self.output_jump_count(&snapshot.ipv6_mangle) != 0 && ipv6_chain.is_empty())
        {
            return PolicyIdentityResolution::Collision;
        }

        let has_chain_state = !ipv4_chain.is_empty() || !ipv6_chain.is_empty();
        let compatible = self
            .candidates()
            .iter()
            .copied()
            .filter(|identity| {
                prefix_matches(
                    &ipv4_chain,
                    &self.ipv4_owned_chain_lines_for(*identity),
                ) && prefix_matches(
                    &ipv6_chain,
                    &self.ipv6_owned_chain_lines_for(*identity),
                )
            })
            .collect::<Vec<_>>();

        if has_chain_state && compatible.is_empty() {
            return PolicyIdentityResolution::Collision;
        }

        let candidates = if has_chain_state {
            compatible
        } else {
            self.candidates().to_vec()
        };

        if let Some(active) = self.active_identity {
            if !candidates.contains(&active) {
                return PolicyIdentityResolution::Collision;
            }
            if self.audit_reserved_policy_space(snapshot, active) == MangleAuditResult::Clean {
                return PolicyIdentityResolution::Selected(active);
            }
            return PolicyIdentityResolution::Collision;
        }

        for candidate in candidates {
            self.active_identity = Some(candidate);
            if self.audit_reserved_policy_space(snapshot, candidate) == MangleAuditResult::Clean {
                return PolicyIdentityResolution::Selected(candidate);
            }
        }

        self.active_identity = None;
        PolicyIdentityResolution::Collision
    }

    pub fn verify_fail_closed_base(
        &self,
        snapshot: &RootPolicySnapshot,
    ) -> Result<(), RootPolicyStructuralFailure> {
        let identity = self
            .active_identity
            .ok_or(RootPolicyStructuralFailure::IdentityUnavailable)?;
        if self.audit_reserved_policy_space(snapshot, identity) != MangleAuditResult::Clean {
            return Err(RootPolicyStructuralFailure::ReservedPolicyCollision);
        }
        if self.mangle_family_state(&snapshot.ipv4_mangle, true)
            != Some(MangleFamilyState::AttachedExact)
            || self.mangle_family_state(&snapshot.ipv6_mangle, false)
                != Some(MangleFamilyState::AttachedExact)
        {
            return Err(RootPolicyStructuralFailure::MangleMismatch);
        }
        if !snapshot.ipv4_rules.iter().any(|line| self.is_owned_ipv4_guard(line))
            || !snapshot.ipv6_rules.iter().any(|line| self.is_owned_ipv6_guard(line))
        {
            return Err(RootPolicyStructuralFailure::GuardMismatch);
        }
        if !self.owned_ipv4_lookup_tables(&snapshot.ipv4_rules).is_empty() {
            return Err(RootPolicyStructuralFailure::LookupStillPresent);
        }
        Ok(())
    }

    pub fn verify_exact_cleanup(&self, snapshot: &RootPolicySnapshot) -> bool {
        let chain = self.chain_name();
        self.owned_ipv4_lookup_tables(&snapshot.ipv4_rules).is_empty()
            && !snapshot.ipv4_rules.iter().any(|line| self.is_owned_ipv4_guard(line))
            && !snapshot.ipv6_rules.iter().any(|line| self.is_owned_ipv6_guard(line))
            && !snapshot
                .ipv4_mangle
                .iter()
                .any(|line| line.contains(chain) || line == &self.legacy_selector_line())
            && !snapshot
                .ipv6_mangle
                .iter()
                .any(|line| line.contains(chain) || line == &self.legacy_selector_line())
    }

    pub fn has_any_product_signature(&mut self, snapshot: &RootPolicySnapshot) -> bool {
        let chain = self.chain_name();
        if snapshot
            .ipv4_mangle
            .iter()
            .any(|line| line.contains(chain) || line == &self.legacy_selector_line())
            || snapshot
                .ipv6_mangle
                .iter()
                .any(|line| line.contains(chain) || line == &self.legacy_selector_line())
        {
            return true;
        }

        let previous = self.active_identity;
        let candidates = self.candidates().to_vec();
        for candidate in candidates {
            self.active_identity = Some(candidate);
            let found = snapshot
                .ipv4_rules
                .iter()
                .any(|line| self.is_owned_ipv4_lookup(line) || self.is_owned_ipv4_guard(line))
                || snapshot
                    .ipv6_rules
                    .iter()
                    .any(|line| self.is_owned_ipv6_guard(line));
            if found {
                self.active_identity = previous;
                return true;
            }
        }
        self.active_identity = previous;
        false
    }

    pub fn mangle_family_state(
        &self,
        lines: &[String],
        ipv4: bool,
    ) -> Option<MangleFamilyState> {
        let identity = self.active_identity?;
        let chain = self.chain_name();
        let definition = format!("-N {chain}");
        let definition_count = lines.iter().filter(|line| *line == &definition).count();
        let jump = self.output_jump();
        let jump_count = lines.iter().filter(|line| *line == &jump).count();
        let actual = chain_lines(lines, chain);
        let expected = if ipv4 {
            self.ipv4_owned_chain_lines_for(identity)
        } else {
            self.ipv6_owned_chain_lines_for(identity)
        };

        if definition_count == 0 {
            return Some(if jump_count == 0 {
                MangleFamilyState::Missing
            } else {
                MangleFamilyState::InvalidReferenced
            });
        }
        if definition_count != 1 {
            return Some(MangleFamilyState::InvalidReferenced);
        }
        if jump_count != 0 && actual != expected {
            return Some(MangleFamilyState::InvalidReferenced);
        }
        if jump_count > 1 {
            return Some(MangleFamilyState::AttachedDuplicateExact);
        }
        if jump_count == 1 {
            return Some(MangleFamilyState::AttachedExact);
        }
        if actual == expected {
            Some(MangleFamilyState::DetachedExact)
        } else {
            Some(MangleFamilyState::DetachedMismatch)
        }
    }

    pub fn audit_reserved_policy_space(
        &self,
        snapshot: &RootPolicySnapshot,
        identity: PolicyIdentity,
    ) -> MangleAuditResult {
        if snapshot
            .ipv4_rules
            .iter()
            .any(|line| self.is_foreign_reserved_ipv4_line(line, identity))
            || snapshot
                .ipv6_rules
                .iter()
                .any(|line| self.is_foreign_reserved_ipv6_line(line, identity))
        {
            return MangleAuditResult::Collision;
        }

        let ipv4 = audit_mangle_output(
            &snapshot.ipv4_mangle,
            &self.ipv4_allowed_mangle_lines_for(identity),
            self.chain_name(),
            identity.mark_value(),
        );
        if ipv4 != MangleAuditResult::Clean {
            return ipv4;
        }
        audit_mangle_output(
            &snapshot.ipv6_mangle,
            &self.ipv6_allowed_mangle_lines_for(identity),
            self.chain_name(),
            identity.mark_value(),
        )
    }

    pub fn stale_owner_jump_uids(&self, lines: &[String]) -> Vec<u32> {
        let mut result = Vec::new();
        for line in lines {
            let Some(uid) = self.exact_owner_jump_uid(line) else {
                continue;
            };
            if uid != self.product_uid && !result.contains(&uid) {
                result.push(uid);
            }
        }
        result
    }

    pub fn stale_owner_jump_delete(&self, binary: &str, stale_uid: u32) -> String {
        format!(
            "{binary} -t mangle -D OUTPUT -m owner --uid-owner {stale_uid} -j {}",
            self.chain_name()
        )
    }

    pub fn is_exact_known_product_state(&self, lines: &[String], ipv4: bool) -> bool {
        let chain = self.chain_name();
        if lines.iter().filter(|line| *line == &format!("-N {chain}")).count() != 1 {
            return false;
        }

        let actual_chain = chain_lines(lines, chain);
        let matching = self
            .candidates()
            .iter()
            .copied()
            .filter(|identity| {
                let expected = if ipv4 {
                    self.ipv4_owned_chain_lines_for(*identity)
                } else {
                    self.ipv6_owned_chain_lines_for(*identity)
                };
                actual_chain == expected
            })
            .count();
        if matching != 1 {
            return false;
        }

        let expected_chain = actual_chain.iter().collect::<HashSet<_>>();
        lines.iter().filter(|line| line.contains(chain)).all(|line| {
            line == &format!("-N {chain}")
                || expected_chain.contains(line)
                || self.exact_owner_jump_uid(line).is_some()
        })
    }

    fn exact_owner_jump_uid(&self, line: &str) -> Option<u32> {
        let tokens = line.split_whitespace().collect::<Vec<_>>();
        if tokens.len() != 8
            || tokens[0] != "-A"
            || tokens[1] != "OUTPUT"
            || tokens[2] != "-m"
            || tokens[3] != "owner"
            || tokens[4] != "--uid-owner"
            || tokens[6] != "-j"
            || tokens[7] != self.chain_name()
        {
            return None;
        }
        let uid = tokens[5].parse::<u32>().ok()?;
        (uid != 0).then_some(uid)
    }

    pub fn output_jump_count(&self, lines: &[String]) -> usize {
        let jump = self.output_jump();
        lines.iter().filter(|line| *line == &jump).count()
    }

    pub fn output_jump(&self) -> String {
        format!(
            "-A OUTPUT -m owner --uid-owner {} -j {}",
            self.product_uid,
            self.chain_name()
        )
    }

    pub fn output_jump_delete(&self, binary: &str) -> String {
        format!(
            "{binary} -t mangle -D OUTPUT -m owner --uid-owner {} -j {}",
            self.product_uid,
            self.chain_name()
        )
    }

    pub fn create_chain_command(&self, binary: &str) -> String {
        format!("{binary} -t mangle -N {}", self.chain_name())
    }

    pub fn flush_chain_command(&self, binary: &str) -> String {
        format!("{binary} -t mangle -F {}", self.chain_name())
    }

    pub fn delete_chain_command(&self, binary: &str) -> String {
        format!("{binary} -t mangle -X {}", self.chain_name())
    }

    pub fn output_jump_add(&self, binary: &str) -> String {
        format!("{binary} -t mangle {}", self.output_jump())
    }

    pub fn ipv4_owned_chain_lines(&self) -> Option<Vec<String>> {
        self.active_identity
            .map(|identity| self.ipv4_owned_chain_lines_for(identity))
    }

    pub fn ipv6_owned_chain_lines(&self) -> Option<Vec<String>> {
        self.active_identity
            .map(|identity| self.ipv6_owned_chain_lines_for(identity))
    }

    pub fn legacy_selector_line(&self) -> String {
        format!(
            "-A OUTPUT -m owner --uid-owner {} -m conntrack --ctstate NEW -j MARK --set-xmark {}/{}",
            self.product_uid,
            self.legacy_mark_hex(),
            self.legacy_mark_hex(),
        )
    }

    pub fn legacy_selector_check(&self, binary: &str) -> String {
        format!(
            "{binary} -t mangle -C OUTPUT -m owner --uid-owner {} -m conntrack --ctstate NEW -j MARK --set-xmark {}/{}",
            self.product_uid,
            self.legacy_mark_hex(),
            self.legacy_mark_hex(),
        )
    }

    pub fn legacy_selector_delete(&self, binary: &str) -> String {
        format!(
            "{binary} -t mangle -D OUTPUT -m owner --uid-owner {} -m conntrack --ctstate NEW -j MARK --set-xmark {}/{}",
            self.product_uid,
            self.legacy_mark_hex(),
            self.legacy_mark_hex(),
        )
    }

    pub fn ipv4_guard_add(&self) -> Option<String> {
        self.active_identity.map(|identity| {
            format!(
                "ip -4 rule add pref {} fwmark {}/{} unreachable",
                identity.guard_priority(),
                identity.mark_hex(),
                identity.mark_hex(),
            )
        })
    }

    pub fn ipv6_guard_add(&self) -> Option<String> {
        self.active_identity.map(|identity| {
            format!(
                "ip -6 rule add pref {} fwmark {}/{} unreachable",
                identity.guard_priority(),
                identity.mark_hex(),
                identity.mark_hex(),
            )
        })
    }

    pub fn ipv4_guard_delete(&self) -> Option<String> {
        self.active_identity.map(|identity| {
            format!(
                "ip -4 rule del pref {} fwmark {}/{} unreachable",
                identity.guard_priority(),
                identity.mark_hex(),
                identity.mark_hex(),
            )
        })
    }

    pub fn ipv6_guard_delete(&self) -> Option<String> {
        self.active_identity.map(|identity| {
            format!(
                "ip -6 rule del pref {} fwmark {}/{} unreachable",
                identity.guard_priority(),
                identity.mark_hex(),
                identity.mark_hex(),
            )
        })
    }

    pub fn ipv4_lookup_add(&self, table: &str) -> Option<String> {
        if !is_safe_table_token(table) {
            return None;
        }
        self.active_identity.map(|identity| {
            format!(
                "ip -4 rule add pref {} fwmark {}/{} lookup {table}",
                identity.lookup_priority(),
                identity.mark_hex(),
                identity.mark_hex(),
            )
        })
    }

    pub fn ipv4_lookup_delete(&self, table: &str) -> Option<String> {
        if !is_safe_table_token(table) {
            return None;
        }
        self.active_identity.map(|identity| {
            format!(
                "ip -4 rule del pref {} fwmark {}/{} lookup {table}",
                identity.lookup_priority(),
                identity.mark_hex(),
                identity.mark_hex(),
            )
        })
    }

    pub fn owned_ipv4_lookup_tables(&self, lines: &[String]) -> Vec<String> {
        let Some(identity) = self.active_identity else {
            return Vec::new();
        };
        let mut result = Vec::new();
        for line in lines {
            if rpdb_priority(line) != Some(identity.lookup_priority()) {
                continue;
            }
            let tokens = line.split_whitespace().collect::<Vec<_>>();
            let mark = token_after(&tokens, "fwmark");
            let table = token_after(&tokens, "lookup");
            let expected_mark = mark_spec(identity);
            if mark == Some(expected_mark.as_str()) {
                if let Some(table) = table.filter(|table| is_safe_table_token(table)) {
                    if !result.iter().any(|existing| existing == table) {
                        result.push(table.to_owned());
                    }
                }
            }
        }
        result
    }

    pub fn is_owned_ipv4_guard(&self, line: &str) -> bool {
        self.is_owned_guard(line)
    }

    pub fn is_owned_ipv6_guard(&self, line: &str) -> bool {
        self.is_owned_guard(line)
    }

    pub fn is_owned_ipv4_lookup(&self, line: &str) -> bool {
        !self.owned_ipv4_lookup_tables(&[line.to_owned()]).is_empty()
    }

    fn is_owned_guard(&self, line: &str) -> bool {
        let Some(identity) = self.active_identity else {
            return false;
        };
        if rpdb_priority(line) != Some(identity.guard_priority()) {
            return false;
        }
        let tokens = line.split_whitespace().collect::<Vec<_>>();
        let expected_mark = mark_spec(identity);
        token_after(&tokens, "fwmark") == Some(expected_mark.as_str())
            && tokens.iter().any(|token| *token == "unreachable")
    }

    fn is_foreign_reserved_ipv4_line(&self, line: &str, identity: PolicyIdentity) -> bool {
        if self.line_is_owned_lookup_for(line, identity) || self.line_is_owned_guard_for(line, identity)
        {
            return false;
        }
        let priority = rpdb_priority(line);
        priority == Some(identity.lookup_priority())
            || priority == Some(identity.guard_priority())
            || rpdb_line_touches_reserved_mark(line, identity.mark_value())
    }

    fn is_foreign_reserved_ipv6_line(&self, line: &str, identity: PolicyIdentity) -> bool {
        if self.line_is_owned_guard_for(line, identity) {
            return false;
        }
        let priority = rpdb_priority(line);
        priority == Some(identity.lookup_priority())
            || priority == Some(identity.guard_priority())
            || rpdb_line_touches_reserved_mark(line, identity.mark_value())
    }

    fn line_is_owned_lookup_for(&self, line: &str, identity: PolicyIdentity) -> bool {
        if rpdb_priority(line) != Some(identity.lookup_priority()) {
            return false;
        }
        let tokens = line.split_whitespace().collect::<Vec<_>>();
        let expected_mark = mark_spec(identity);
        token_after(&tokens, "fwmark") == Some(expected_mark.as_str())
            && token_after(&tokens, "lookup").is_some_and(is_safe_table_token)
    }

    fn line_is_owned_guard_for(&self, line: &str, identity: PolicyIdentity) -> bool {
        if rpdb_priority(line) != Some(identity.guard_priority()) {
            return false;
        }
        let tokens = line.split_whitespace().collect::<Vec<_>>();
        let expected_mark = mark_spec(identity);
        token_after(&tokens, "fwmark") == Some(expected_mark.as_str())
            && tokens.iter().any(|token| *token == "unreachable")
    }

    fn ipv4_owned_chain_lines_for(&self, identity: PolicyIdentity) -> Vec<String> {
        let chain = self.chain_name();
        let mark = identity.mark_hex();
        vec![
            format!("-A {chain} -d 127.0.0.0/8 -j RETURN"),
            format!(
                "-A {chain} -j CONNMARK --restore-mark --nfmask {mark} --ctmask {mark}"
            ),
            format!(
                "-A {chain} -m conntrack --ctstate NEW -j MARK --set-xmark {mark}/{mark}"
            ),
            format!(
                "-A {chain} -m conntrack --ctstate NEW -m mark --mark {mark}/{mark} -j CONNMARK --save-mark --nfmask {mark} --ctmask {mark}"
            ),
        ]
    }

    fn ipv6_owned_chain_lines_for(&self, identity: PolicyIdentity) -> Vec<String> {
        let chain = self.chain_name();
        let mark = identity.mark_hex();
        vec![
            format!("-A {chain} -d ::1/128 -j RETURN"),
            format!(
                "-A {chain} -j CONNMARK --restore-mark --nfmask {mark} --ctmask {mark}"
            ),
            format!(
                "-A {chain} -m conntrack --ctstate NEW -j MARK --set-xmark {mark}/{mark}"
            ),
            format!(
                "-A {chain} -m conntrack --ctstate NEW -m mark --mark {mark}/{mark} -j CONNMARK --save-mark --nfmask {mark} --ctmask {mark}"
            ),
        ]
    }

    fn ipv4_allowed_mangle_lines_for(&self, identity: PolicyIdentity) -> HashSet<String> {
        let mut allowed = HashSet::new();
        allowed.insert(format!("-N {}", self.chain_name()));
        allowed.insert(self.output_jump());
        allowed.extend(self.ipv4_owned_chain_lines_for(identity));
        allowed.insert(self.legacy_selector_line());
        allowed
    }

    fn ipv6_allowed_mangle_lines_for(&self, identity: PolicyIdentity) -> HashSet<String> {
        let mut allowed = HashSet::new();
        allowed.insert(format!("-N {}", self.chain_name()));
        allowed.insert(self.output_jump());
        allowed.extend(self.ipv6_owned_chain_lines_for(identity));
        allowed.insert(self.legacy_selector_line());
        allowed
    }
}

pub fn is_safe_interface_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 15
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
}

pub fn is_safe_table_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 32
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
}

pub fn referenced_tables(lines: &[String]) -> Vec<String> {
    let mut tables = Vec::new();
    for line in lines {
        let tokens = line.split_whitespace().collect::<Vec<_>>();
        for keyword in ["lookup", "table"] {
            if let Some(table) = token_after(&tokens, keyword).filter(|table| is_safe_table_token(table))
                && !tables.iter().any(|existing| existing == table)
            {
                tables.push(table.to_owned());
            }
        }
    }
    tables
}

pub fn route_has_default_on_interface(lines: &[String], interface: &str) -> bool {
    if !is_safe_interface_name(interface) {
        return false;
    }
    lines.iter().any(|line| {
        let tokens = line.split_whitespace().collect::<Vec<_>>();
        tokens.first() == Some(&"default") && token_after(&tokens, "dev") == Some(interface)
    })
}

pub fn route_get_uses_interface(output: &str, interface: &str) -> bool {
    if !is_safe_interface_name(interface) {
        return false;
    }
    output.lines().any(|line| {
        let tokens = line.split_whitespace().collect::<Vec<_>>();
        token_after(&tokens, "dev") == Some(interface)
    })
}

pub fn rpdb_line_touches_reserved_mark(line: &str, reserved_mark: u64) -> bool {
    let tokens = line.split_whitespace().collect::<Vec<_>>();
    let Some(spec) = token_after(&tokens, "fwmark") else {
        return false;
    };
    mark_spec_touches(spec, reserved_mark).unwrap_or(true)
}

pub fn audit_mangle_output(
    lines: &[String],
    allowed_product_lines: &HashSet<String>,
    mish_chain: &str,
    candidate_mark: u64,
) -> MangleAuditResult {
    if candidate_mark == 0 {
        return MangleAuditResult::Ambiguous;
    }
    let normalized = lines
        .iter()
        .map(|line| line.trim())
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();

    if normalized
        .iter()
        .any(|line| line.contains(mish_chain) && !allowed_product_lines.contains(*line))
    {
        return MangleAuditResult::Collision;
    }

    let mut user_chains = HashSet::new();
    let mut rules_by_chain: HashMap<&str, Vec<Vec<&str>>> = HashMap::new();
    for line in &normalized {
        let tokens = line.split_whitespace().collect::<Vec<_>>();
        match tokens.first().copied() {
            Some("-N") => {
                if tokens.len() != 2 || !is_safe_chain_name(tokens[1]) || !user_chains.insert(tokens[1])
                {
                    return MangleAuditResult::Ambiguous;
                }
            }
            Some("-A") => {
                if tokens.len() < 3 || !is_safe_chain_name(tokens[1]) {
                    return MangleAuditResult::Ambiguous;
                }
                rules_by_chain.entry(tokens[1]).or_default().push(tokens);
            }
            _ => {}
        }
    }

    fn visit<'a>(
        chain: &'a str,
        rules_by_chain: &'a HashMap<&'a str, Vec<Vec<&'a str>>>,
        user_chains: &'a HashSet<&'a str>,
        allowed: &HashSet<String>,
        candidate_mark: u64,
        states: &mut HashMap<&'a str, u8>,
    ) -> MangleAuditResult {
        match states.get(chain).copied() {
            Some(1) => return MangleAuditResult::Ambiguous,
            Some(2) => return MangleAuditResult::Clean,
            _ => {}
        }
        states.insert(chain, 1);

        for tokens in rules_by_chain.get(chain).into_iter().flatten() {
            let line = tokens.join(" ");
            if !allowed.contains(&line) {
                match audit_mark_semantics(tokens, candidate_mark) {
                    MangleAuditResult::Clean => {}
                    other => return other,
                }
            }

            match chain_target(tokens) {
                ChainTarget::Malformed => return MangleAuditResult::Ambiguous,
                ChainTarget::None => {}
                ChainTarget::Named(target) => {
                    if user_chains.contains(target) {
                        let nested = visit(
                            target,
                            rules_by_chain,
                            user_chains,
                            allowed,
                            candidate_mark,
                            states,
                        );
                        if nested != MangleAuditResult::Clean {
                            return nested;
                        }
                    } else if rules_by_chain.contains_key(target) {
                        return MangleAuditResult::Ambiguous;
                    }
                }
            }
        }

        states.insert(chain, 2);
        MangleAuditResult::Clean
    }

    visit(
        "OUTPUT",
        &rules_by_chain,
        &user_chains,
        allowed_product_lines,
        candidate_mark,
        &mut HashMap::new(),
    )
}

fn audit_mark_semantics(tokens: &[&str], candidate_mark: u64) -> MangleAuditResult {
    let mut saw_known_mark_operation = false;
    let mut mark_target = false;
    let mut connmark_target = false;

    for (index, token) in tokens.iter().enumerate() {
        match *token {
            "-j" | "--jump" | "-g" | "--goto" => {
                let Some(target) = tokens.get(index + 1) else {
                    return MangleAuditResult::Ambiguous;
                };
                mark_target |= *target == "MARK";
                connmark_target |= *target == "CONNMARK";
            }
            "--mark" | "--set-xmark" | "--set-mark" => {
                saw_known_mark_operation = true;
                let Some(spec) = tokens.get(index + 1) else {
                    return MangleAuditResult::Ambiguous;
                };
                match mark_spec_touches(spec, candidate_mark) {
                    Some(true) => return MangleAuditResult::Collision,
                    Some(false) => {}
                    None => return MangleAuditResult::Ambiguous,
                }
            }
            "--nfmask" | "--ctmask" => {
                saw_known_mark_operation = true;
                let Some(mask) = tokens.get(index + 1).and_then(|raw| parse_unsigned(raw)) else {
                    return MangleAuditResult::Ambiguous;
                };
                if mask > IPV4_FULL_MASK {
                    return MangleAuditResult::Ambiguous;
                }
                if mask & candidate_mark != 0 {
                    return MangleAuditResult::Collision;
                }
            }
            "--restore-mark" | "--save-mark" => {
                saw_known_mark_operation = true;
                let nfmask = option_mask(tokens, "--nfmask").unwrap_or(IPV4_FULL_MASK);
                let ctmask = option_mask(tokens, "--ctmask").unwrap_or(IPV4_FULL_MASK);
                if nfmask & candidate_mark != 0 || ctmask & candidate_mark != 0 {
                    return MangleAuditResult::Collision;
                }
            }
            "--and-mark" | "--or-mark" | "--xor-mark" => {
                return MangleAuditResult::Collision;
            }
            _ => {}
        }
    }

    if (mark_target || connmark_target) && !saw_known_mark_operation {
        MangleAuditResult::Ambiguous
    } else {
        MangleAuditResult::Clean
    }
}

fn option_mask(tokens: &[&str], option: &str) -> Option<u64> {
    let index = tokens.iter().position(|token| *token == option)?;
    let value = parse_unsigned(tokens.get(index + 1)?)?;
    (value <= IPV4_FULL_MASK).then_some(value)
}

enum ChainTarget<'a> {
    None,
    Malformed,
    Named(&'a str),
}

fn chain_target<'a>(tokens: &'a [&'a str]) -> ChainTarget<'a> {
    let mut target = None;
    for (index, token) in tokens.iter().enumerate() {
        if !matches!(*token, "-j" | "--jump" | "-g" | "--goto") {
            continue;
        }
        let Some(candidate) = tokens.get(index + 1).copied() else {
            return ChainTarget::Malformed;
        };
        if candidate.starts_with('-') {
            return ChainTarget::Malformed;
        }
        if target.is_some_and(|existing| existing != candidate) {
            return ChainTarget::Malformed;
        }
        target = Some(candidate);
    }
    target.map_or(ChainTarget::None, ChainTarget::Named)
}

fn is_safe_chain_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 28
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b':' | b'+' | b'-')
        })
}

fn prefix_matches(actual: &[String], expected: &[String]) -> bool {
    actual.len() <= expected.len() && actual == &expected[..actual.len()]
}

fn chain_lines(lines: &[String], chain: &str) -> Vec<String> {
    let prefix = format!("-A {chain} ");
    lines
        .iter()
        .filter(|line| line.starts_with(&prefix))
        .cloned()
        .collect()
}

fn token_after<'a>(tokens: &'a [&'a str], keyword: &str) -> Option<&'a str> {
    let index = tokens.iter().position(|token| *token == keyword)?;
    tokens.get(index + 1).copied()
}

fn rpdb_priority(line: &str) -> Option<u32> {
    line.trim()
        .split_once(':')
        .and_then(|(raw, _)| raw.parse::<u32>().ok())
}

fn mark_spec(identity: PolicyIdentity) -> String {
    // All accepted policy identities deliberately use mark == mask.
    format!("{0}/{0}", identity.mark_hex())
}

fn mark_spec_touches(spec: &str, reserved_mark: u64) -> Option<bool> {
    let mut parts = spec.split('/');
    let value = parse_unsigned(parts.next()?)?;
    let mask = parts
        .next()
        .map(parse_unsigned)
        .unwrap_or(Some(IPV4_FULL_MASK))?;
    if parts.next().is_some() || value > IPV4_FULL_MASK || mask > IPV4_FULL_MASK {
        return None;
    }
    Some(mask & reserved_mark != 0)
}

fn parse_unsigned(raw: &str) -> Option<u64> {
    if let Some(hex) = raw.strip_prefix("0x").or_else(|| raw.strip_prefix("0X")) {
        (!hex.is_empty()).then(|| u64::from_str_radix(hex, 16).ok()).flatten()
    } else {
        raw.parse::<u64>().ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(uid: u32) -> RootPolicyContract {
        RootPolicyContract::new(uid, RootPolicyNamespace::Release).expect("contract")
    }

    fn empty_snapshot() -> RootPolicySnapshot {
        RootPolicySnapshot::new(
            vec!["0: from all lookup local".into(), "32766: from all lookup main".into()],
            vec!["0: from all lookup local".into(), "32766: from all lookup main".into()],
            Vec::new(),
            Vec::new(),
        )
    }

    #[test]
    fn snapshot_parser_accepts_only_safe_unique_tables_and_reserved_overlap() {
        assert_eq!(
            referenced_tables(&[
                "1000: from all lookup 100".into(),
                "1001: from all table rmnet_data0".into(),
                "1002: from all lookup 100".into(),
                "1003: from all lookup bad/table".into(),
            ]),
            vec!["100".to_string(), "rmnet_data0".to_string()]
        );
        assert!(is_safe_interface_name("rmnet_data0"));
        assert!(!is_safe_interface_name("rmnet data0"));
        assert!(rpdb_line_touches_reserved_mark(
            "9500: from all fwmark 0x200000/0x200000",
            0x20_0000
        ));
        assert!(!rpdb_line_touches_reserved_mark(
            "9500: from all fwmark 0x400000/0x400000",
            0x20_0000
        ));
    }

    #[test]
    fn exact_foreign_first_candidate_selects_second_without_mutating_snapshot() {
        let mut contract = release(10123);
        let mut snapshot = empty_snapshot();
        snapshot
            .ipv4_mangle
            .push("-A OUTPUT -j MARK --set-xmark 0x200000/0x200000".into());

        let selected = contract.resolve_identity(&snapshot);
        let PolicyIdentityResolution::Selected(identity) = selected else {
            panic!("identity should be selected");
        };
        assert_eq!(identity.mark_hex(), "0x400000");
        assert!(snapshot.ipv4_mangle[0].contains("0x200000"));
    }

    #[test]
    fn every_bounded_candidate_occupied_fails_closed_without_selection() {
        let mut contract = release(10123);
        let mut snapshot = empty_snapshot();
        for identity in contract.candidates() {
            snapshot.ipv4_mangle.push(format!(
                "-A OUTPUT -j MARK --set-xmark {0}/{0}",
                identity.mark_hex()
            ));
        }
        assert_eq!(
            contract.resolve_identity(&snapshot),
            PolicyIdentityResolution::Collision
        );
        assert_eq!(contract.active_identity(), None);
    }

    #[test]
    fn selected_identity_is_stable_when_earlier_collision_disappears() {
        let mut contract = release(10123);
        let mut snapshot = empty_snapshot();
        snapshot
            .ipv4_mangle
            .push("-A OUTPUT -j MARK --set-xmark 0x200000/0x200000".into());
        let PolicyIdentityResolution::Selected(second) = contract.resolve_identity(&snapshot) else {
            panic!("second identity");
        };
        assert_eq!(second.mark_hex(), "0x400000");

        snapshot.ipv4_mangle.clear();
        let PolicyIdentityResolution::Selected(still_second) = contract.resolve_identity(&snapshot)
        else {
            panic!("stable identity");
        };
        assert_eq!(still_second, second);
    }

    #[test]
    fn output_collision_audit_matches_reachable_semantics_only() {
        let allowed = HashSet::new();
        assert_eq!(
            audit_mangle_output(
                &["-A INPUT -j MARK --set-xmark 0x0/0x200000".into()],
                &allowed,
                RELEASE_MISH_CHAIN,
                0x20_0000,
            ),
            MangleAuditResult::Clean
        );
        assert_eq!(
            audit_mangle_output(
                &["-A OUTPUT -j MARK --set-xmark 0x0/0x200000".into()],
                &allowed,
                RELEASE_MISH_CHAIN,
                0x20_0000,
            ),
            MangleAuditResult::Collision
        );
        assert_eq!(
            audit_mangle_output(
                &[
                    "-N OUTER".into(),
                    "-N INNER".into(),
                    "-A OUTPUT -j OUTER".into(),
                    "-A OUTER -g INNER".into(),
                    "-A INNER -m mark --mark 0x0/0x200000 -j RETURN".into(),
                ],
                &allowed,
                RELEASE_MISH_CHAIN,
                0x20_0000,
            ),
            MangleAuditResult::Collision
        );
    }

    #[test]
    fn duplicate_exact_owner_jump_is_repairable_not_foreign_structure() {
        let mut contract = release(10123);
        let snapshot = empty_snapshot();
        let PolicyIdentityResolution::Selected(_) = contract.resolve_identity(&snapshot) else {
            panic!("identity");
        };
        let mut lines = vec![format!("-N {}", contract.chain_name())];
        lines.extend(contract.ipv4_owned_chain_lines().expect("chain"));
        lines.push(contract.output_jump());
        lines.push(contract.output_jump());
        assert_eq!(
            contract.mangle_family_state(&lines, true),
            Some(MangleFamilyState::AttachedDuplicateExact)
        );
        lines.push(format!("-A {} -j DROP", contract.chain_name()));
        assert_eq!(
            contract.mangle_family_state(&lines, true),
            Some(MangleFamilyState::InvalidReferenced)
        );
    }

    #[test]
    fn route_validation_is_exact_and_safe() {
        assert!(route_has_default_on_interface(
            &["default via 10.0.0.1 dev rmnet_data0".into()],
            "rmnet_data0"
        ));
        assert!(!route_has_default_on_interface(
            &["default via 10.0.0.1 dev rmnet_data1".into()],
            "rmnet_data0"
        ));
        assert!(route_get_uses_interface(
            "1.1.1.1 dev rmnet_data0 src 10.0.0.2\n",
            "rmnet_data0"
        ));
        assert!(!route_get_uses_interface(
            "1.1.1.1 dev rmnet_data0 src 10.0.0.2\n",
            "rmnet_data1"
        ));
    }

    #[test]
    fn debug_namespace_never_claims_release_chain_or_mark() {
        let debug = RootPolicyContract::new(10123, RootPolicyNamespace::Debug).expect("debug");
        assert_eq!(debug.chain_name(), DEBUG_MISH_CHAIN);
        assert_eq!(debug.candidates()[0].mark_hex(), "0x2000000");
        assert_ne!(debug.chain_name(), RELEASE_MISH_CHAIN);
        assert_ne!(debug.candidates()[0], RELEASE_POLICY_CANDIDATES[0]);
    }
}
