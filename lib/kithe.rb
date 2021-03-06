require "kithe/engine"

module Kithe
  # for ruby-progressbar
  STANDARD_PROGRESS_BAR_FORMAT = "%a %t: |%B| %R/s %c/%u %p%% %e"

  # ActiveRecord will automatically pick this up for all our models.
  # We don't want an isolated engine, but we do want this, part of what isolated engines do.
  def self.table_name_prefix
    'kithe_'
  end

  # We don't want an isolated engine, but we do want this, part of what isolated engines do.
  # Will make generators use namespace scope, among other things.
  def self.railtie_namespace
    Kithe::Engine
  end
end
