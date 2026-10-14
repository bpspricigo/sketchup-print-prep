# Print Prep — SketchUp extension loader.
# Checks a model for 3D printing: which parts are real solids, how the model
# fits a printer bed at a given scale, and which parts get too thin.

require 'sketchup.rb'
require 'extensions.rb'

module BrunoTools
  module PrintPrep
    PLUGIN_ID  = 'print_prep'.freeze
    PLUGIN_DIR = File.join(File.dirname(__FILE__), PLUGIN_ID).freeze

    unless file_loaded?(__FILE__)
      ext = SketchupExtension.new('Print Prep', File.join(PLUGIN_DIR, 'main'))
      ext.description = 'Prepare house models for 3D printing: solid check, ' \
                        'scale vs. printer bed, thin-part detection.'
      ext.version     = '0.4.0'
      ext.creator     = 'Bruno'
      Sketchup.register_extension(ext, true)
      EXTENSION = ext
      file_loaded(__FILE__)
    end
  end
end
