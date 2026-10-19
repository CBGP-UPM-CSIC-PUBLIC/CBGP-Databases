# frozen_string_literal: true

# Exercises currency handling through the actual CBGP::Dataset layer (field
# lookup from the ontology fixture, coercion, and the friendly-error path),
# as opposed to spec/lib/currency_spec.rb which tests the pure parse/format
# helpers in isolation.
RSpec.describe CBGP::Dataset do
  # personnel_project_total_funding is a field currently wired to the
  # currency widget (local:object-class Currency / local:widget-type
  # currency in the ontology fixture). If that ever gets renamed/removed/
  # repointed to a different class in the ontology, these specs should fail
  # loudly rather than silently stop testing anything real.
  #
  # 'project' itself is no longer a valid form type - Sara's 2026-08
  # restructuring split it into per-funding-type forms (european_research_
  # project, national_regional_research_project, private_research_project,
  # personnel_project); personnel_project is used throughout this file.
  let(:currency_questionclass) { 'personnel_project_total_funding' }
  let(:currency_method) { :total_funding }

  before do
    field = described_class.fields_for('personnel_project').find { |f| f[:questionclass] == currency_questionclass }
    raise "fixture ontology no longer has a '#{currency_questionclass}' field - update this spec" unless field

    unless field[:class] == 'currency'
      raise "'#{currency_questionclass}' is no longer a currency field - update this spec"
    end
  end

  describe '#coerce_value with class "currency"' do
    subject(:dataset) { described_class.new(type: 'personnel_project') }

    it 'coerces valid US-style input to the canonical decimal form' do
      expect(dataset.coerce_value('15,000.5', 'currency', 'Single')).to eq('15000.50')
    end

    it 'coerces valid Spanish-style input to the same canonical form' do
      Thread.current[:language] = 'es'
      expect(dataset.coerce_value('15.000,50', 'currency', 'Single')).to eq('15000.50')
    end

    it 'raises a friendly ArgumentError for unparseable input' do
      expect { dataset.coerce_value('fifteen thousand', 'currency', 'Single') }
        .to raise_error(ArgumentError, /doesn't look like a valid amount/)
    end

    it 'treats a blank value as blank, not an error' do
      expect(dataset.coerce_value('', 'currency', 'Single')).to eq('')
    end
  end

  describe '.load_from_params_and_write' do
    # personnel_project's required fields include real DNI/NIE/PAS cross-references
    # to member (beneficiary_nie, project_pi_nie) -
    # unlike the old "project" form's required fields, which were plain
    # strings. Required-field handling can look up the record's primary id via
    # get_primary_id -> execute_search -> a live SPARQL
    # endpoint, which this suite must never depend on. Stub it out so a
    # missing/unreachable triplestore can't fail these currency-focused specs for
    # an unrelated reason.
    before { allow(described_class).to receive(:get_primary_id).and_return(nil) }

    # personnel_project requires several other fields besides the currency
    # one under test here (local:requires-field) - all must be submitted too,
    # otherwise every case in this describe block would also fail with
    # unrelated "X is required" errors on top of whatever currency behavior
    # is actually under test.
    let(:base_params) do
      {
        'database' => 'personnel_project',
        'primary_id' => '',
        'project_title' => 'Test Project',
        'beneficiary_nie' => '12345678Z',
        'project_pi_nie' => '12345678Z',
        'project_funding_entity' => 'Test Funding Entity',
        'project_affiliation' => 'affiliation_upm',
        'project_application_url' => 'https://example.org/call/TEST-CODE',
        'project_start_date' => '2026-01-01',
        'project_end_date' => '2026-12-31',
        'project_internal_code' => 'TEST-INTERNAL'
      }
    end

    context 'with an invalid currency amount' do
      let(:params) { base_params.merge(currency_questionclass => 'fifteen thousand') }

      it 'raises ValidationError instead of a raw ArgumentError' do
        expect { described_class.load_from_params_and_write(params: params) }
          .to raise_error(described_class::ValidationError)
      end

      it 'reports the failing field by its human label, not its internal method name' do
        described_class.load_from_params_and_write(params: params)
      rescue described_class::ValidationError => e
        expect(e.errors).to contain_exactly(
          hash_including(label: 'Total funding', message: a_string_matching(/doesn't look like a valid amount/))
        )
      end

      it 'never reaches write_dataset_to_db (nothing is persisted on a validation failure)' do
        allow(described_class).to receive(:write_dataset_to_db)
        begin
          described_class.load_from_params_and_write(params: params)
        rescue described_class::ValidationError
          nil
        end
        expect(described_class).not_to have_received(:write_dataset_to_db)
      end
    end

    context 'with a valid currency amount' do
      let(:params) { base_params.merge(currency_questionclass => '15,000.50') }

      before { allow(described_class).to receive(:write_dataset_to_db) }

      it 'stores the canonical decimal form and writes exactly once' do
        dataset = described_class.load_from_params_and_write(params: params)
        expect(dataset.public_send(currency_method)).to eq('15000.50')
        expect(described_class).to have_received(:write_dataset_to_db).once
      end
    end
  end

  describe '.new_from_raw_params' do
    it 'echoes back exactly what was submitted, unvalidated, for redisplay after a ValidationError' do
      params = { 'database' => 'personnel_project', 'primary_id' => '', currency_questionclass => 'fifteen thousand' }
      dataset = described_class.new_from_raw_params(type: 'personnel_project', params: params)
      expect(dataset.public_send(currency_method)).to eq('fifteen thousand')
    end
  end

  # Regression coverage for a 2026-07-09 finding: project_overheads was left
  # tagged local:object-class String/local:widget-type text in the ontology
  # while five sibling money fields (including project_total_funding, tested
  # above) were Currency. An untyped money field silently skips locale-aware
  # parsing/validation on save, locale-aware formatting on display, and
  # canonical-form normalization on search (see spec/lib/search_accent_spec.rb
  # and lib/queries.rb's currency branch in build_search_query). Every field
  # semantically representing a monetary amount must carry class "currency" so
  # none of that happens by accident again.
  #
  # Field list refreshed for Sara's 2026-08 project-fields restructuring
  # (personnel_project's own currency fields, since generic "project" no
  # longer exists). NOTE: while refreshing this list, national_regional_
  # research_project's year4_direct_costs field was found still mistagged
  # (local:widget-type points at "https://w3id.org/cbgp-app#currency" -
  # lowercase "cbgp-app", not "CBGP-App" - so it doesn't match "currency"
  # here) - the same class of bug this spec exists to catch, flagged to Sara
  # separately rather than silently added to this personnel_project-only list.
  describe 'monetary field coverage' do
    monetary_questionclasses = %w[
      personnel_project_total_funding
      project_annual_cbgp_overheads
      project_annual_income
      project_cbgp_overheads
    ]

    monetary_questionclasses.each do |qc|
      it "tags #{qc} as a currency field in the ontology" do
        field = described_class.fields_for('personnel_project').find { |f| f[:questionclass] == qc }
        raise "fixture ontology no longer has a '#{qc}' field - update this spec" unless field

        expect(field[:class]).to eq('currency')
      end
    end
  end
end
