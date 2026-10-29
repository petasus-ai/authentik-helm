"""Petasus additions to authentik's Django settings.

authentik imports this module as data.user_settings when it is mounted at
/data/user_settings.py (authentik/root/settings.py: _update_settings("data.user_settings")).
"""

from django.utils.cache import patch_vary_headers
from django.utils.html import escape
from django.utils.translation import get_language, get_language_from_request, override


class BrowserLanguageMiddleware:
    """Answer in the browser's language when neither the brand nor the user picked one.

    authentik 2026.8 runs Django's LocaleMiddleware and writes <html lang> itself, which lets
    the brand CSS pick its copy; this keeps the rule explicit: the brand's or the user's
    locale when one is pinned, else the browser's.

    Flow pages in the sidebar_left layout also get the hero as real text, so it can be
    selected and copied and shows before the flow script loads (.ps-hero in petasus-login.css).
    """

    # authentik/flows/templates/if/flow.html writes the flow's layout into window.authentik.flow
    sidebar_flow_marker = b'"layout": "sidebar_left"'

    # Korean pages read Korean, every other language reads English; "\n" breaks a line
    hero_copy = {
        "en": {
            "eyebrow": "BUILT FOR ENTERPRISE AI",
            "headline": "AI infrastructure,\nvirtualized for enterprise.",
            "lead": "Petasus virtualizes your GPU infrastructure with the isolation,\n"
            "performance and operations enterprises expect.",
            "tiles": [
                ("GPU virtualization", "GPUs for VMs and clusters"),
                ("Multi-tenancy", "Per-workspace isolation"),
                ("High-speed networking", "SR-IOV · RDMA · VPC"),
                ("Unified operations", "Monitoring · Audit · History"),
            ],
        },
        "ko": {
            "eyebrow": "BUILT FOR ENTERPRISE AI",
            "headline": "AI 인프라 가상화,\n엔터프라이즈의 기준으로.",
            "lead": "격리, 성능, 운영까지 기업 환경이 요구하는 수준으로\nGPU 인프라를 가상화합니다.",
            "tiles": [
                ("GPU 가상화", "GPU를 가상머신·클러스터에 할당"),
                ("멀티테넌시", "워크스페이스·프로젝트별 격리"),
                ("고성능 네트워크", "SR-IOV · RDMA · VPC"),
                ("통합 운영", "모니터링 · 감사 · 이력"),
            ],
        },
    }

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        user = getattr(request, "user", None)
        pinned = request.brand.default_locale or (
            user is not None and user.is_authenticated and user.locale(request)
        )
        if pinned:
            response = self.get_response(request)
            language = get_language()
        else:
            language = get_language_from_request(request)
            with override(language):
                response = self.get_response(request)
            patch_vary_headers(response, ("Accept-Language",))
        return self._tag_html(response, language)

    @classmethod
    def _tag_html(cls, response, language):
        if response.streaming or not response.get("Content-Type", "").startswith("text/html"):
            return response
        content = response.content
        if cls.sidebar_flow_marker in content:
            content = content.replace(b"<body>", b"<body>" + cls._hero_html(language), 1)
        response.content = content
        return response

    @classmethod
    def _hero_html(cls, language):
        copy = cls.hero_copy["ko" if (language or "").lower().startswith("ko") else "en"]

        def lines(text):
            return escape(text).replace("\n", "<br>")

        tiles = "".join(
            f"<li><strong>{escape(name)}</strong><span>{escape(detail)}</span></li>"
            for name, detail in copy["tiles"]
        )
        return (
            '<aside class="ps-hero">'
            f'<p class="ps-hero__eyebrow">{escape(copy["eyebrow"])}</p>'
            f'<h2 class="ps-hero__headline">{lines(copy["headline"])}</h2>'
            f'<p class="ps-hero__lead">{lines(copy["lead"])}</p>'
            f'<ul class="ps-hero__tiles">{tiles}</ul>'
            "</aside>"
        ).encode()


MIDDLEWARE = ["data.user_settings.BrowserLanguageMiddleware"]
