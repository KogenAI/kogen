def review_reply(provider_ok, verdict_valid):
    if not provider_ok:
        return "malformed_verdict"
    if not verdict_valid:
        return "malformed_verdict"
    return "accept"
