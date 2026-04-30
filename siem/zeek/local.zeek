@load base/protocols/http
@load base/protocols/dns
@load base/protocols/ssl
@load base/protocols/smb

event http_header(c: connection, is_orig: bool, name: string, value: string) {
    # Match canonical JNDI pattern and common obfuscation variants where j,n,d,i
    # appear scattered inside ${...} (e.g. ${${lower:j}ndi:}).
    if ( is_orig && /\$\{[^}]*j[^}]*n[^}]*d[^}]*i[^}]*:/ in value )
        NOTICE([$note=Notice::LOG, $conn=c,
                $msg=fmt("Log4Shell JNDI in header %s: %s", name, value),
                $identifier=cat(c$id)]);
}

event dns_request(c: connection, msg: dns_msg, query: string, qtype: count, qclass: count) {
    # Heuristic: labels > 40 chars are characteristic of DNS tunnel data exfil
    # (legitimate public labels rarely exceed 30 chars).
    local parts = split_string(query, /\./);
    if ( |parts| > 0 ) {
        local first_label = parts[0];
        if ( |first_label| > 40 )
            NOTICE([$note=Notice::LOG, $conn=c,
                    $msg=fmt("Suspicious long DNS label (tunnel?): %s", query),
                    $identifier=cat(c$id)]);
    }
}
