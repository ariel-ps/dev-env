# Open Chrome with PS proxy and Google AI mode flags (US country override)
chrome-ai() {
  local proxy="${1:-http://127.0.0.1:3636}"
  open -a "Google Chrome" --args \
    --profile-directory="Profile 24" \
    --proxy-server="$proxy" \
    --variations-override-country=us \
    --enable-features=AiModeOmniboxEntryPoint,AimEnabled,AimServerEligibilityEnabled,AimServerEligibilityIncludeClientLocale,AimServerEligibilityIncludeClientCountry,AimUrlNavigationFetchEnabled,AimServerRequestOnStartupEnabled,AimServerRequestOnIdentityChangeEnabled,DynamicProfileCountry,WebUIOmniboxAimPopup,DynamicAimSubmit,Glic,GlicWarming,GlicDefaultTabContextSetting,GlicUserStatusCheck,GlicUseSessionCountryForFiltering
}

# Kill all running Chrome instances
chrome-killall() {
  pkill -x "Google Chrome" 2>/dev/null && echo "Chrome killed" || echo "Chrome not running"
}

# Open Chrome with PS proxy and Google AI mode flags (no country override)
chrome-ai-intl() {
  local proxy="${1:-http://127.0.0.1:3636}"
  open -a "Google Chrome" --args \
    --profile-directory="Profile 24" \
    --proxy-server="$proxy" \
    --enable-features=AiModeOmniboxEntryPoint,AimEnabled,AimServerEligibilityEnabled,AimServerEligibilityIncludeClientLocale,AimServerEligibilityIncludeClientCountry,AimUrlNavigationFetchEnabled,AimServerRequestOnStartupEnabled,AimServerRequestOnIdentityChangeEnabled,DynamicProfileCountry,WebUIOmniboxAimPopup,DynamicAimSubmit,Glic,GlicWarming,GlicDefaultTabContextSetting,GlicUserStatusCheck,GlicUseSessionCountryForFiltering
}
