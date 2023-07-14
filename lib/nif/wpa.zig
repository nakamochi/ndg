const std = @import("std");
const mem = std.mem;
const Thread = std.Thread;

const WPACtrl = opaque {};
pub const ReqCallback = *const fn ([*:0]const u8, usize) callconv(.C) void;

extern fn wpa_ctrl_open(ctrl_path: [*:0]const u8) ?*WPACtrl;
extern fn wpa_ctrl_close(ctrl: *WPACtrl) void;
extern fn wpa_ctrl_request(ctrl: *WPACtrl, cmd: [*:0]const u8, clen: usize, reply: [*:0]u8, rlen: *usize, cb: ?ReqCallback) c_int;
extern fn wpa_ctrl_pending(ctrl: *WPACtrl) c_int;
extern fn wpa_ctrl_recv(ctrl: *WPACtrl, reply: [*:0]u8, reply_len: *usize) c_int;

pub const Control = struct {
    //mu: Thread.Mutext = .{},
    wpa_ctrl: *WPACtrl,
    attached: bool = false,

    const Self = @This();
    pub const Error = error{
        NameTooLong,
        WpaCtrlFailure,
        WpaCtrlTimeout,
        WpaCtrlAttach,
        WpaCtrlDetach,
        WpaCtrlScanStart,
        WpaCtrlSaveConfig,
        WpaCtrlAddNetwork,
        WpaCtrlRemoveNetwork,
        WpaCtrlSelectNetwork,
        WpaCtrlEnableNetwork,
        WpaCtrlSetNetworkParam,
    } || std.fmt.BufPrintError;

    // TODO: using this in Self.request
    pub const RequestCallback = *const fn (msg: [:0]const u8) void;

    fn wpaErr(i: c_int) Error {
        return switch (i) {
            -2 => error.WpaCtrlTimeout,
            else => error.WpaCtrlFailure,
        };
    }

    /// open a WPA control interface identified by the path.
    /// the returned instance must be close'd when done to free resources.
    /// TODO: describe @android: and @abstract: prefixes
    /// TODO: what about UDP, on windows?
    pub fn open(path: [:0]const u8) Error!Self {
        const ctrl = wpa_ctrl_open(path);
        if (ctrl == null) {
            return error.WpaCtrlFailure;
        }
        return Self{ .wpa_ctrl = ctrl.? };
    }

    /// release all associated resources, including detach'ing a monitor.
    pub fn close(self: *Self) Error!void {
        //self.mu.lock();
        //defer self.mu.unlock();
        if (self.attached) {
            try self.detach();
        }
        wpa_ctrl_close(self.wpa_ctrl);
    }

    /// start control interface events monitoring.
    /// presence of events is reported by self.pending; then can be read using self.receive.
    pub fn attach(self: *Self) Error!void {
        self.reqOK("ATTACH") catch return error.WpaCtrlAttach;
        self.attached = true;
    }

    /// stop control interface events monitoring.
    pub fn detach(self: *Self) Error!void {
        self.reqOK("DETACH") catch return error.WpaCtrlDetach;
        self.attached = false;
    }

    /// request wifi scan
    pub fn scan(self: *Self) Error!void {
        self.reqOK("SCAN") catch return error.WpaCtrlScanStart;
    }

    /// dump in-memory config to a file, typically /etc/wpa_supplicant/wpa_supplicant.conf.
    /// fails if update_config set to 0.
    pub fn saveConfig(self: *Self) Error!void {
        self.reqOK("SAVE_CONFIG") catch return error.WpaCtrlSaveConfig;
    }

    /// add a new blank network, returning its ID.
    /// the newly added network can be configured with self.setNetworkParam.
    pub fn addNetwork(self: *Self) (Error || std.fmt.ParseIntError)!u32 {
        var buf: [10:0]u8 = undefined;
        const resp = self.request("ADD_NETWORK", &buf, null) catch return error.WpaCtrlAddNetwork;
        return std.fmt.parseUnsigned(u32, mem.trim(u8, resp, "\n "), 10);
    }

    pub fn removeNetwork(self: *Self, id: u32) Error!void {
        var buf: [48:0]u8 = undefined;
        const cmd = try std.fmt.bufPrintZ(&buf, "REMOVE_NETWORK {d}", .{id});
        return self.reqOK(cmd) catch return error.WpaCtrlRemoveNetwork;
    }

    pub fn selectNetwork(self: *Self, id: u32) Error!void {
        var buf: [48:0]u8 = undefined;
        const cmd = try std.fmt.bufPrintZ(&buf, "SELECT_NETWORK {d}", .{id});
        return self.reqOK(cmd) catch return error.WpaCtrlSelectNetwork;
    }

    pub fn enableNetwork(self: *Self, id: u32) Error!void {
        var buf: [48:0]u8 = undefined;
        const cmd = try std.fmt.bufPrintZ(&buf, "ENABLE_NETWORK {d}", .{id});
        return self.reqOK(cmd) catch return error.WpaCtrlEnableNetwork;
    }

    pub fn setNetworkParam(self: *Self, id: u32, name: []const u8, value: []const u8) Error!void {
        var buf: [512:0]u8 = undefined;
        const cmd = try std.fmt.bufPrintZ(&buf, "SET_NETWORK {d} {s} {s}", .{ id, name, value });
        return self.reqOK(cmd) catch return error.WpaCtrlSetNetworkParam;
    }

    fn reqOK(self: *Self, cmd: [:0]const u8) Error!void {
        var buf: [10:0]u8 = undefined;
        const resp = try self.request(cmd, &buf, null);
        if (!mem.startsWith(u8, resp, "OK\n")) {
            return error.WpaCtrlFailure;
        }
    }

    /// send a command to the control interface, returning a response owned by buf.
    /// callback receives a message from the same buf.
    pub fn request(self: Self, cmd: [:0]const u8, buf: [:0]u8, callback: ?ReqCallback) Error![]const u8 {
        //self.mu.lock();
        //defer self.mu.unlock();
        var n: usize = buf.len;
        const e = wpa_ctrl_request(self.wpa_ctrl, cmd, cmd.len, buf, &n, callback);
        if (e != 0) {
            return wpaErr(e);
        }
        return buf[0..n];
    }

    /// reports whether pending messages are waiting to be read using self.receive.
    /// requires self to be attach'ed.
    pub fn pending(self: Self) Error!bool {
        //self.mu.lock();
        //defer self.mu.unlock();
        const n = wpa_ctrl_pending(self.wpa_ctrl);
        if (n < 0) {
            return wpaErr(n);
        }
        return n > 0;
    }

    /// retrieve a pending message using the provided buf.
    /// returned slice is owned by the buf.
    /// requires self to be attach'ed.
    pub fn receive(self: Self, buf: [:0]u8) Error![]const u8 {
        //self.mu.lock();
        //defer self.mu.unlock();
        var n: usize = buf.len;
        const e = wpa_ctrl_recv(self.wpa_ctrl, buf, &n);
        if (e != 0) {
            return wpaErr(e);
        }
        return buf[0..n];
    }
};

//pub const WPA_CTRL_REQ = "CTRL-REQ-";
//pub const WPA_CTRL_RSP = "CTRL-RSP-";
//pub const WPA_EVENT_CONNECTED = "CTRL-EVENT-CONNECTED ";
//pub const WPA_EVENT_DISCONNECTED = "CTRL-EVENT-DISCONNECTED ";
//pub const WPA_EVENT_ASSOC_REJECT = "CTRL-EVENT-ASSOC-REJECT ";
//pub const WPA_EVENT_AUTH_REJECT = "CTRL-EVENT-AUTH-REJECT ";
//pub const WPA_EVENT_TERMINATING = "CTRL-EVENT-TERMINATING ";
//pub const WPA_EVENT_PASSWORD_CHANGED = "CTRL-EVENT-PASSWORD-CHANGED ";
//pub const WPA_EVENT_EAP_NOTIFICATION = "CTRL-EVENT-EAP-NOTIFICATION ";
//pub const WPA_EVENT_EAP_STARTED = "CTRL-EVENT-EAP-STARTED ";
//pub const WPA_EVENT_EAP_PROPOSED_METHOD = "CTRL-EVENT-EAP-PROPOSED-METHOD ";
//pub const WPA_EVENT_EAP_METHOD = "CTRL-EVENT-EAP-METHOD ";
//pub const WPA_EVENT_EAP_PEER_CERT = "CTRL-EVENT-EAP-PEER-CERT ";
//pub const WPA_EVENT_EAP_PEER_ALT = "CTRL-EVENT-EAP-PEER-ALT ";
//pub const WPA_EVENT_EAP_TLS_CERT_ERROR = "CTRL-EVENT-EAP-TLS-CERT-ERROR ";
//pub const WPA_EVENT_EAP_STATUS = "CTRL-EVENT-EAP-STATUS ";
//pub const WPA_EVENT_EAP_RETRANSMIT = "CTRL-EVENT-EAP-RETRANSMIT ";
//pub const WPA_EVENT_EAP_RETRANSMIT2 = "CTRL-EVENT-EAP-RETRANSMIT2 ";
//pub const WPA_EVENT_EAP_SUCCESS = "CTRL-EVENT-EAP-SUCCESS ";
//pub const WPA_EVENT_EAP_SUCCESS2 = "CTRL-EVENT-EAP-SUCCESS2 ";
//pub const WPA_EVENT_EAP_FAILURE = "CTRL-EVENT-EAP-FAILURE ";
//pub const WPA_EVENT_EAP_FAILURE2 = "CTRL-EVENT-EAP-FAILURE2 ";
//pub const WPA_EVENT_EAP_TIMEOUT_FAILURE = "CTRL-EVENT-EAP-TIMEOUT-FAILURE ";
//pub const WPA_EVENT_EAP_TIMEOUT_FAILURE2 = "CTRL-EVENT-EAP-TIMEOUT-FAILURE2 ";
//pub const WPA_EVENT_EAP_ERROR_CODE = "EAP-ERROR-CODE ";
//pub const WPA_EVENT_TEMP_DISABLED = "CTRL-EVENT-SSID-TEMP-DISABLED ";
//pub const WPA_EVENT_REENABLED = "CTRL-EVENT-SSID-REENABLED ";
//pub const WPA_EVENT_SCAN_STARTED = "CTRL-EVENT-SCAN-STARTED ";
//pub const WPA_EVENT_SCAN_RESULTS = "CTRL-EVENT-SCAN-RESULTS ";
//pub const WPA_EVENT_SCAN_FAILED = "CTRL-EVENT-SCAN-FAILED ";
//pub const WPA_EVENT_STATE_CHANGE = "CTRL-EVENT-STATE-CHANGE ";
//pub const WPA_EVENT_BSS_ADDED = "CTRL-EVENT-BSS-ADDED ";
//pub const WPA_EVENT_BSS_REMOVED = "CTRL-EVENT-BSS-REMOVED ";
//pub const WPA_EVENT_NETWORK_NOT_FOUND = "CTRL-EVENT-NETWORK-NOT-FOUND ";
//pub const WPA_EVENT_SIGNAL_CHANGE = "CTRL-EVENT-SIGNAL-CHANGE ";
//pub const WPA_EVENT_BEACON_LOSS = "CTRL-EVENT-BEACON-LOSS ";
//pub const WPA_EVENT_REGDOM_CHANGE = "CTRL-EVENT-REGDOM-CHANGE ";
//pub const WPA_EVENT_CHANNEL_SWITCH_STARTED = "CTRL-EVENT-STARTED-CHANNEL-SWITCH ";
//pub const WPA_EVENT_CHANNEL_SWITCH = "CTRL-EVENT-CHANNEL-SWITCH ";
//pub const WPA_EVENT_SAE_UNKNOWN_PASSWORD_IDENTIFIER = "CTRL-EVENT-SAE-UNKNOWN-PASSWORD-IDENTIFIER ";
//pub const WPA_EVENT_UNPROT_BEACON = "CTRL-EVENT-UNPROT-BEACON ";
//pub const WPA_EVENT_DO_ROAM = "CTRL-EVENT-DO-ROAM ";
//pub const WPA_EVENT_SKIP_ROAM = "CTRL-EVENT-SKIP-ROAM ";
//pub const WPA_EVENT_SUBNET_STATUS_UPDATE = "CTRL-EVENT-SUBNET-STATUS-UPDATE ";
//pub const IBSS_RSN_COMPLETED = "IBSS-RSN-COMPLETED ";
//pub const WPA_EVENT_FREQ_CONFLICT = "CTRL-EVENT-FREQ-CONFLICT ";
//pub const WPA_EVENT_AVOID_FREQ = "CTRL-EVENT-AVOID-FREQ ";
//pub const WPA_EVENT_NETWORK_ADDED = "CTRL-EVENT-NETWORK-ADDED ";
//pub const WPA_EVENT_NETWORK_REMOVED = "CTRL-EVENT-NETWORK-REMOVED ";
//pub const WPA_EVENT_MSCS_RESULT = "CTRL-EVENT-MSCS-RESULT ";
//pub const WPS_EVENT_OVERLAP = "WPS-OVERLAP-DETECTED ";
//pub const WPS_EVENT_AP_AVAILABLE_PBC = "WPS-AP-AVAILABLE-PBC ";
//pub const WPS_EVENT_AP_AVAILABLE_AUTH = "WPS-AP-AVAILABLE-AUTH ";
//pub const WPS_EVENT_AP_AVAILABLE_PIN = "WPS-AP-AVAILABLE-PIN ";
//pub const WPS_EVENT_AP_AVAILABLE = "WPS-AP-AVAILABLE ";
//pub const WPS_EVENT_CRED_RECEIVED = "WPS-CRED-RECEIVED ";
//pub const WPS_EVENT_M2D = "WPS-M2D ";
//pub const WPS_EVENT_FAIL = "WPS-FAIL ";
//pub const WPS_EVENT_SUCCESS = "WPS-SUCCESS ";
//pub const WPS_EVENT_TIMEOUT = "WPS-TIMEOUT ";
//pub const WPS_EVENT_ACTIVE = "WPS-PBC-ACTIVE ";
//pub const WPS_EVENT_DISABLE = "WPS-PBC-DISABLE ";
//pub const WPS_EVENT_ENROLLEE_SEEN = "WPS-ENROLLEE-SEEN ";
//pub const WPS_EVENT_OPEN_NETWORK = "WPS-OPEN-NETWORK ";
//pub const WPA_EVENT_SCS_RESULT = "CTRL-EVENT-SCS-RESULT ";
//pub const WPA_EVENT_DSCP_POLICY = "CTRL-EVENT-DSCP-POLICY ";
//pub const WPS_EVENT_ER_AP_ADD = "WPS-ER-AP-ADD ";
//pub const WPS_EVENT_ER_AP_REMOVE = "WPS-ER-AP-REMOVE ";
//pub const WPS_EVENT_ER_ENROLLEE_ADD = "WPS-ER-ENROLLEE-ADD ";
//pub const WPS_EVENT_ER_ENROLLEE_REMOVE = "WPS-ER-ENROLLEE-REMOVE ";
//pub const WPS_EVENT_ER_AP_SETTINGS = "WPS-ER-AP-SETTINGS ";
//pub const WPS_EVENT_ER_SET_SEL_REG = "WPS-ER-AP-SET-SEL-REG ";
//pub const DPP_EVENT_AUTH_SUCCESS = "DPP-AUTH-SUCCESS ";
//pub const DPP_EVENT_AUTH_INIT_FAILED = "DPP-AUTH-INIT-FAILED ";
//pub const DPP_EVENT_NOT_COMPATIBLE = "DPP-NOT-COMPATIBLE ";
//pub const DPP_EVENT_RESPONSE_PENDING = "DPP-RESPONSE-PENDING ";
//pub const DPP_EVENT_SCAN_PEER_QR_CODE = "DPP-SCAN-PEER-QR-CODE ";
//pub const DPP_EVENT_AUTH_DIRECTION = "DPP-AUTH-DIRECTION ";
//pub const DPP_EVENT_CONF_RECEIVED = "DPP-CONF-RECEIVED ";
//pub const DPP_EVENT_CONF_SENT = "DPP-CONF-SENT ";
//pub const DPP_EVENT_CONF_FAILED = "DPP-CONF-FAILED ";
//pub const DPP_EVENT_CONN_STATUS_RESULT = "DPP-CONN-STATUS-RESULT ";
//pub const DPP_EVENT_CONFOBJ_AKM = "DPP-CONFOBJ-AKM ";
//pub const DPP_EVENT_CONFOBJ_SSID = "DPP-CONFOBJ-SSID ";
//pub const DPP_EVENT_CONFOBJ_SSID_CHARSET = "DPP-CONFOBJ-SSID-CHARSET ";
//pub const DPP_EVENT_CONFOBJ_PASS = "DPP-CONFOBJ-PASS ";
//pub const DPP_EVENT_CONFOBJ_PSK = "DPP-CONFOBJ-PSK ";
//pub const DPP_EVENT_CONNECTOR = "DPP-CONNECTOR ";
//pub const DPP_EVENT_C_SIGN_KEY = "DPP-C-SIGN-KEY ";
//pub const DPP_EVENT_PP_KEY = "DPP-PP-KEY ";
//pub const DPP_EVENT_NET_ACCESS_KEY = "DPP-NET-ACCESS-KEY ";
//pub const DPP_EVENT_SERVER_NAME = "DPP-SERVER-NAME ";
//pub const DPP_EVENT_CERTBAG = "DPP-CERTBAG ";
//pub const DPP_EVENT_CACERT = "DPP-CACERT ";
//pub const DPP_EVENT_MISSING_CONNECTOR = "DPP-MISSING-CONNECTOR ";
//pub const DPP_EVENT_NETWORK_ID = "DPP-NETWORK-ID ";
//pub const DPP_EVENT_CONFIGURATOR_ID = "DPP-CONFIGURATOR-ID ";
//pub const DPP_EVENT_RX = "DPP-RX ";
//pub const DPP_EVENT_TX = "DPP-TX ";
//pub const DPP_EVENT_TX_STATUS = "DPP-TX-STATUS ";
//pub const DPP_EVENT_FAIL = "DPP-FAIL ";
//pub const DPP_EVENT_PKEX_T_LIMIT = "DPP-PKEX-T-LIMIT ";
//pub const DPP_EVENT_INTRO = "DPP-INTRO ";
//pub const DPP_EVENT_CONF_REQ_RX = "DPP-CONF-REQ-RX ";
//pub const DPP_EVENT_CHIRP_STOPPED = "DPP-CHIRP-STOPPED ";
//pub const DPP_EVENT_MUD_URL = "DPP-MUD-URL ";
//pub const DPP_EVENT_BAND_SUPPORT = "DPP-BAND-SUPPORT ";
//pub const DPP_EVENT_CSR = "DPP-CSR ";
//pub const DPP_EVENT_CHIRP_RX = "DPP-CHIRP-RX ";
//pub const MESH_GROUP_STARTED = "MESH-GROUP-STARTED ";
//pub const MESH_GROUP_REMOVED = "MESH-GROUP-REMOVED ";
//pub const MESH_PEER_CONNECTED = "MESH-PEER-CONNECTED ";
//pub const MESH_PEER_DISCONNECTED = "MESH-PEER-DISCONNECTED ";
//pub const MESH_SAE_AUTH_FAILURE = "MESH-SAE-AUTH-FAILURE ";
//pub const MESH_SAE_AUTH_BLOCKED = "MESH-SAE-AUTH-BLOCKED ";
//pub const WMM_AC_EVENT_TSPEC_ADDED = "TSPEC-ADDED ";
//pub const WMM_AC_EVENT_TSPEC_REMOVED = "TSPEC-REMOVED ";
//pub const WMM_AC_EVENT_TSPEC_REQ_FAILED = "TSPEC-REQ-FAILED ";
//pub const P2P_EVENT_DEVICE_FOUND = "P2P-DEVICE-FOUND ";
//pub const P2P_EVENT_DEVICE_LOST = "P2P-DEVICE-LOST ";
//pub const P2P_EVENT_GO_NEG_REQUEST = "P2P-GO-NEG-REQUEST ";
//pub const P2P_EVENT_GO_NEG_SUCCESS = "P2P-GO-NEG-SUCCESS ";
//pub const P2P_EVENT_GO_NEG_FAILURE = "P2P-GO-NEG-FAILURE ";
//pub const P2P_EVENT_GROUP_FORMATION_SUCCESS = "P2P-GROUP-FORMATION-SUCCESS ";
//pub const P2P_EVENT_GROUP_FORMATION_FAILURE = "P2P-GROUP-FORMATION-FAILURE ";
//pub const P2P_EVENT_GROUP_STARTED = "P2P-GROUP-STARTED ";
//pub const P2P_EVENT_GROUP_REMOVED = "P2P-GROUP-REMOVED ";
//pub const P2P_EVENT_CROSS_CONNECT_ENABLE = "P2P-CROSS-CONNECT-ENABLE ";
//pub const P2P_EVENT_CROSS_CONNECT_DISABLE = "P2P-CROSS-CONNECT-DISABLE ";
//pub const P2P_EVENT_PROV_DISC_SHOW_PIN = "P2P-PROV-DISC-SHOW-PIN ";
//pub const P2P_EVENT_PROV_DISC_ENTER_PIN = "P2P-PROV-DISC-ENTER-PIN ";
//pub const P2P_EVENT_PROV_DISC_PBC_REQ = "P2P-PROV-DISC-PBC-REQ ";
//pub const P2P_EVENT_PROV_DISC_PBC_RESP = "P2P-PROV-DISC-PBC-RESP ";
//pub const P2P_EVENT_PROV_DISC_FAILURE = "P2P-PROV-DISC-FAILURE";
//pub const P2P_EVENT_SERV_DISC_REQ = "P2P-SERV-DISC-REQ ";
//pub const P2P_EVENT_SERV_DISC_RESP = "P2P-SERV-DISC-RESP ";
//pub const P2P_EVENT_SERV_ASP_RESP = "P2P-SERV-ASP-RESP ";
//pub const P2P_EVENT_INVITATION_RECEIVED = "P2P-INVITATION-RECEIVED ";
//pub const P2P_EVENT_INVITATION_RESULT = "P2P-INVITATION-RESULT ";
//pub const P2P_EVENT_INVITATION_ACCEPTED = "P2P-INVITATION-ACCEPTED ";
//pub const P2P_EVENT_FIND_STOPPED = "P2P-FIND-STOPPED ";
//pub const P2P_EVENT_PERSISTENT_PSK_FAIL = "P2P-PERSISTENT-PSK-FAIL id=";
//pub const P2P_EVENT_PRESENCE_RESPONSE = "P2P-PRESENCE-RESPONSE ";
//pub const P2P_EVENT_NFC_BOTH_GO = "P2P-NFC-BOTH-GO ";
//pub const P2P_EVENT_NFC_PEER_CLIENT = "P2P-NFC-PEER-CLIENT ";
//pub const P2P_EVENT_NFC_WHILE_CLIENT = "P2P-NFC-WHILE-CLIENT ";
//pub const P2P_EVENT_FALLBACK_TO_GO_NEG = "P2P-FALLBACK-TO-GO-NEG ";
//pub const P2P_EVENT_FALLBACK_TO_GO_NEG_ENABLED = "P2P-FALLBACK-TO-GO-NEG-ENABLED ";
//pub const ESS_DISASSOC_IMMINENT = "ESS-DISASSOC-IMMINENT ";
//pub const P2P_EVENT_REMOVE_AND_REFORM_GROUP = "P2P-REMOVE-AND-REFORM-GROUP ";
//pub const P2P_EVENT_P2PS_PROVISION_START = "P2PS-PROV-START ";
//pub const P2P_EVENT_P2PS_PROVISION_DONE = "P2PS-PROV-DONE ";
//pub const INTERWORKING_AP = "INTERWORKING-AP ";
//pub const INTERWORKING_EXCLUDED = "INTERWORKING-BLACKLISTED ";
//pub const INTERWORKING_NO_MATCH = "INTERWORKING-NO-MATCH ";
//pub const INTERWORKING_ALREADY_CONNECTED = "INTERWORKING-ALREADY-CONNECTED ";
//pub const INTERWORKING_SELECTED = "INTERWORKING-SELECTED ";
//pub const CRED_ADDED = "CRED-ADDED ";
//pub const CRED_MODIFIED = "CRED-MODIFIED ";
//pub const CRED_REMOVED = "CRED-REMOVED ";
//pub const GAS_RESPONSE_INFO = "GAS-RESPONSE-INFO ";
//pub const GAS_QUERY_START = "GAS-QUERY-START ";
//pub const GAS_QUERY_DONE = "GAS-QUERY-DONE ";
//pub const ANQP_QUERY_DONE = "ANQP-QUERY-DONE ";
//pub const RX_ANQP = "RX-ANQP ";
//pub const RX_HS20_ANQP = "RX-HS20-ANQP ";
//pub const RX_HS20_ANQP_ICON = "RX-HS20-ANQP-ICON ";
//pub const RX_HS20_ICON = "RX-HS20-ICON ";
//pub const RX_MBO_ANQP = "RX-MBO-ANQP ";
//pub const RX_VENUE_URL = "RX-VENUE-URL ";
//pub const HS20_SUBSCRIPTION_REMEDIATION = "HS20-SUBSCRIPTION-REMEDIATION ";
//pub const HS20_DEAUTH_IMMINENT_NOTICE = "HS20-DEAUTH-IMMINENT-NOTICE ";
//pub const HS20_T_C_ACCEPTANCE = "HS20-T-C-ACCEPTANCE ";
//pub const EXT_RADIO_WORK_START = "EXT-RADIO-WORK-START ";
//pub const EXT_RADIO_WORK_TIMEOUT = "EXT-RADIO-WORK-TIMEOUT ";
//pub const RRM_EVENT_NEIGHBOR_REP_RXED = "RRM-NEIGHBOR-REP-RECEIVED ";
//pub const RRM_EVENT_NEIGHBOR_REP_FAILED = "RRM-NEIGHBOR-REP-REQUEST-FAILED ";
//pub const WPS_EVENT_PIN_NEEDED = "WPS-PIN-NEEDED ";
//pub const WPS_EVENT_NEW_AP_SETTINGS = "WPS-NEW-AP-SETTINGS ";
//pub const WPS_EVENT_REG_SUCCESS = "WPS-REG-SUCCESS ";
//pub const WPS_EVENT_AP_SETUP_LOCKED = "WPS-AP-SETUP-LOCKED ";
//pub const WPS_EVENT_AP_SETUP_UNLOCKED = "WPS-AP-SETUP-UNLOCKED ";
//pub const WPS_EVENT_AP_PIN_ENABLED = "WPS-AP-PIN-ENABLED ";
//pub const WPS_EVENT_AP_PIN_DISABLED = "WPS-AP-PIN-DISABLED ";
//pub const WPS_EVENT_PIN_ACTIVE = "WPS-PIN-ACTIVE ";
//pub const WPS_EVENT_CANCEL = "WPS-CANCEL ";
//pub const AP_STA_CONNECTED = "AP-STA-CONNECTED ";
//pub const AP_STA_DISCONNECTED = "AP-STA-DISCONNECTED ";
//pub const AP_STA_POSSIBLE_PSK_MISMATCH = "AP-STA-POSSIBLE-PSK-MISMATCH ";
//pub const AP_STA_POLL_OK = "AP-STA-POLL-OK ";
//pub const AP_REJECTED_MAX_STA = "AP-REJECTED-MAX-STA ";
//pub const AP_REJECTED_BLOCKED_STA = "AP-REJECTED-BLOCKED-STA ";
//pub const HS20_T_C_FILTERING_ADD = "HS20-T-C-FILTERING-ADD ";
//pub const HS20_T_C_FILTERING_REMOVE = "HS20-T-C-FILTERING-REMOVE ";
//pub const AP_EVENT_ENABLED = "AP-ENABLED ";
//pub const AP_EVENT_DISABLED = "AP-DISABLED ";
//pub const INTERFACE_ENABLED = "INTERFACE-ENABLED ";
//pub const INTERFACE_DISABLED = "INTERFACE-DISABLED ";
//pub const ACS_EVENT_STARTED = "ACS-STARTED ";
//pub const ACS_EVENT_COMPLETED = "ACS-COMPLETED ";
//pub const ACS_EVENT_FAILED = "ACS-FAILED ";
//pub const DFS_EVENT_RADAR_DETECTED = "DFS-RADAR-DETECTED ";
//pub const DFS_EVENT_NEW_CHANNEL = "DFS-NEW-CHANNEL ";
//pub const DFS_EVENT_CAC_START = "DFS-CAC-START ";
//pub const DFS_EVENT_CAC_COMPLETED = "DFS-CAC-COMPLETED ";
//pub const DFS_EVENT_NOP_FINISHED = "DFS-NOP-FINISHED ";
//pub const DFS_EVENT_PRE_CAC_EXPIRED = "DFS-PRE-CAC-EXPIRED ";
//pub const AP_CSA_FINISHED = "AP-CSA-FINISHED ";
//pub const P2P_EVENT_LISTEN_OFFLOAD_STOP = "P2P-LISTEN-OFFLOAD-STOPPED ";
//pub const P2P_LISTEN_OFFLOAD_STOP_REASON = "P2P-LISTEN-OFFLOAD-STOP-REASON ";
//pub const BSS_TM_RESP = "BSS-TM-RESP ";
//pub const COLOC_INTF_REQ = "COLOC-INTF-REQ ";
//pub const COLOC_INTF_REPORT = "COLOC-INTF-REPORT ";
//pub const MBO_CELL_PREFERENCE = "MBO-CELL-PREFERENCE ";
