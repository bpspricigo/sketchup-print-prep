# Print Prep — update check against the GitHub Releases of the (public) repo.
#
# A few seconds after SketchUp starts, asks GitHub for the latest release. If it
# is newer than the installed version, asks whether to install it, downloads the
# .rbz and installs it; the new version is active after a SketchUp restart.
# Declining remembers that version so the startup check doesn't ask again;
# "Check for updates" in the menu always asks. Startup failures stay silent.

require 'sketchup.rb'
require 'json'
require 'tmpdir'

module BrunoTools
  module PrintPrep
    module Updater
      REPO        = 'bpspricigo/sketchup-print-prep'.freeze
      LATEST_URL  = "https://api.github.com/repos/#{REPO}/releases/latest".freeze
      ASSET_NAME  = 'print_prep.rbz'.freeze
      START_DELAY = 8 # seconds after load, so startup isn't slowed
      MAX_REDIRECTS = 5

      def self.installed_version
        PrintPrep::EXTENSION.version.to_s
      end

      # manual: started from the menu (report every outcome, ignore "skipped").
      def self.check(manual: false)
        get(LATEST_URL, 'application/vnd.github+json') do |status, body|
          begin
            handle_latest(status, body, manual)
          rescue StandardError => e
            report(manual, "Update check failed: #{e.message}")
          end
        end
      rescue StandardError => e
        report(manual, "Update check failed: #{e.message}")
      end

      def self.handle_latest(status, body, manual)
        if status != 200
          report(manual, "Couldn't reach GitHub to check for updates (HTTP #{status}).")
          return
        end

        release = JSON.parse(body)
        latest  = release['tag_name'].to_s.sub(/\Av/, '')
        asset   = (release['assets'] || []).find { |a| a['name'] == ASSET_NAME }

        if !newer?(latest, installed_version) || asset.nil?
          report(manual, "Print Prep #{installed_version} is up to date.")
        elsif manual || skipped != latest
          offer(latest, asset['browser_download_url'])
        end
      end

      def self.offer(version, url)
        answer = UI.messagebox(
          "Print Prep #{version} is available (you have #{installed_version}).\n\nInstall it now?",
          MB_YESNO
        )
        if answer == IDYES
          download_and_install(version, url)
        else
          Sketchup.write_default(SETTINGS_KEY, 'skipped_version', version)
        end
      end

      def self.download_and_install(version, url)
        Sketchup.status_text = "Print Prep: downloading #{version}…"
        get(url, 'application/octet-stream') do |status, body|
          Sketchup.status_text = ''
          data = body.to_s.dup.force_encoding(Encoding::BINARY)
          unless status == 200 && data.start_with?("PK")
            UI.messagebox("Downloading Print Prep #{version} failed (HTTP #{status}). Try again later.")
            next
          end

          path = File.join(Dir.tmpdir, "print_prep-#{version}.rbz")
          File.binwrite(path, data)
          begin
            Sketchup.install_from_archive(path)
            UI.messagebox("Print Prep #{version} is installed. Restart SketchUp to use it.")
          rescue Interrupt
            # the user cancelled SketchUp's install prompt
          rescue StandardError => e
            UI.messagebox("Installing Print Prep #{version} failed: #{e.message}")
          ensure
            File.delete(path) if File.exist?(path)
          end
        end
      end

      # Async GET that follows redirects (release downloads redirect to a CDN).
      # Yields [status_code, body] on the UI thread.
      def self.get(url, accept, hops = 0, &done)
        req = Sketchup::Http::Request.new(url, Sketchup::Http::GET)
        req.headers = { 'User-Agent' => 'PrintPrep-SketchUp', 'Accept' => accept }
        @pending = req # keep a reference, or the request can be collected mid-flight
        req.start do |_r, res|
          @pending = nil
          location = res.headers['Location'] || res.headers['location']
          if [301, 302, 303, 307, 308].include?(res.status_code) && location && hops < MAX_REDIRECTS
            get(location, accept, hops + 1, &done)
          else
            done.call(res.status_code, res.body)
          end
        end
      end

      def self.newer?(a, b)
        parse = ->(v) { v.split('.').map(&:to_i) }
        (parse.call(a) <=> parse.call(b)) == 1
      end

      def self.skipped
        Sketchup.read_default(SETTINGS_KEY, 'skipped_version', nil)
      end

      def self.report(manual, message)
        UI.messagebox(message) if manual
      end

      unless file_loaded?(__FILE__)
        UI.start_timer(START_DELAY, false) { check }
        file_loaded(__FILE__)
      end
    end
  end
end
