module Kithe
  # join table for n-to-m self-referential "contains" relation
  # between models, mostly intended for (Collection <-> Work)
  class ModelContains < ActiveRecord::Base
    belongs_to :container, foreign_key: "container_id", class_name: "Kithe::Model", inverse_of: :contains_contains
    belongs_to :containee, foreign_key: "containee_id", class_name: "Kithe::Model", inverse_of: :contains_contained_by
  end
end
