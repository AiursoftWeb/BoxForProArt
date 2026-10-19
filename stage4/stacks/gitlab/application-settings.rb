# Public visibility is restricted for non-admin users; GitLab retains its admin exception.
settings = Gitlab::CurrentSettings.current_application_settings
restricted_levels = settings.restricted_visibility_levels | [Gitlab::VisibilityLevel::PUBLIC]

if restricted_levels != settings.restricted_visibility_levels
  updated = ApplicationSettings::UpdateService.new(settings, nil, restricted_visibility_levels: restricted_levels).execute
  raise settings.errors.full_messages.join('; ') unless updated
end

raise 'Public visibility is not restricted' unless settings.reload.restricted_visibility_levels.include?(Gitlab::VisibilityLevel::PUBLIC)

puts 'GitLab Public visibility is restricted; existing visibility defaults are unchanged.'
