# frozen_string_literal: true

# Covers the per-form required-fields mechanism (2026-07-28): a form can mark
# one of its fields mandatory via the ontology's local:requires-field
# property, without that requirement living on the shared question class
# itself.
#
# Sara's 2026-08 project-fields restructuring replaced the old shared
# "project" form (Research vs Personnel, distinguished by dcterms:type) with
# several distinct per-funding-type forms. national_regional_research_project
# stands in for "Research" here, personnel_project for "Personnel" - unlike
# before, each now requires a whole list of fields, not just one, so this
# spec picks one example field unique to each side (present, and required, on
# only that form) to prove the mechanism is genuinely per-form:
#   - cbgp:national_regional_research_project (Research) requires project_call_for_proposal_title
#     (personnel_project doesn't have this field at all). The PI (project_pi_nie) is NOT
#     such an example any more: every project form shares and requires it (2026-10-06).
#   - cbgp:personnel_project (Personnel) requires project_funding_entity
#     (national_regional_research_project doesn't have this field at all).
#     personnel_project_total_funding used to be this example, but Sara's
#     2026-10-15 restructuring stopped requiring it.
RSpec.describe 'per-form required fields' do
  # project_pi_nie is a cross-reference field (references member via
  # member_dni_nie_pas); get_primary_id (primary-id lookup) calls execute_search -> a live
  # SPARQL endpoint if not stubbed, which this suite must never depend on.
  before { allow(CBGP::Dataset).to receive(:get_primary_id).and_return(nil) }

  before do
    {
      'national_regional_research_project' => 'project_call_for_proposal_title',
      'personnel_project' => 'project_funding_entity'
    }.each do |form, qc|
      field = CBGP::Dataset.fields_for(form).find { |f| f[:questionclass] == qc }
      raise "fixture ontology no longer has '#{qc}' on '#{form}' - update this spec" unless field
    end
  end

  describe '#get_form_required_fields_query / .form_required_fields' do
    it 'resolves the Research form (national_regional_research_project) to its full required set' do
      expect(CBGP::Dataset.form_required_fields(form: 'national_regional_research_project')).to eq(Set[
        'project_affiliation',
        'project_application_url',
        'project_call_for_proposal_title',
        'project_funding_institution',
        'project_internal_code',
        'project_pi_nie',
        'project_title'
      ])
      # start/end date are no longer here: they are required only once the
      # project is Awarded (a conditional requirement - see
      # spec/lib/conditional_requirements_spec.rb)
    end

    it 'resolves the Personnel form to its full required set, not overlapping on the Research-only field' do
      required = CBGP::Dataset.form_required_fields(form: 'personnel_project')
      expect(required).to include('project_funding_entity')
      expect(required).not_to include('project_call_for_proposal_title') # Research-only
    end

    it 'returns an empty set for a form with no local:requires-field at all' do
      expect(CBGP::Dataset.form_required_fields(form: 'member')).to eq(Set.new)
    end

    it 'returns an empty set for a nonexistent form class rather than raising' do
      expect(CBGP::Dataset.form_required_fields(form: 'not_a_real_form')).to eq(Set.new)
    end
  end

  describe '.load_from_params_and_write required-field enforcement' do
    # Every other field national_regional_research_project/personnel_project
    # requires must be supplied too, so a test can omit exactly one field and
    # get a clean, single-field ValidationError - not a pile of unrelated
    # "X is required" errors on top of whatever's actually under test.
    let(:research_params) do
      {
        'database' => 'national_regional_research_project',
        'primary_id' => '',
        'project_title' => 'A Research Project',
        'project_pi_nie' => '12345678Z',
        'project_funding_institution' => 'placeholder',
        'project_affiliation' => 'affiliation_upm',
        'project_application_url' => 'https://example.org/call/TEST-CODE',
        'project_call_for_proposal_title' => 'Test Call',
        'project_internal_code' => 'TEST-INTERNAL',
        'project_start_date' => '2026-01-01',
        'project_end_date' => '2026-12-31'
      }
    end

    let(:personnel_params) do
      {
        'database' => 'personnel_project',
        'primary_id' => '',
        'project_title' => 'A Personnel Project',
        'beneficiary_nie' => '12345678Z',
        'project_pi_nie' => '12345678Z',
        'personnel_project_total_funding' => '1000.00',
        'project_funding_entity' => 'Test Funding Entity',
        'project_affiliation' => 'affiliation_upm',
        'project_application_url' => 'https://example.org/call/TEST-CODE',
        'project_internal_code' => 'TEST-INTERNAL',
        'project_start_date' => '2026-01-01',
        'project_end_date' => '2026-12-31'
      }
    end

    context 'on the Research form (project_pi_nie required)' do
      it 'raises ValidationError naming PI DNI/NIE/PAS when project_pi_nie is missing' do
        params = research_params.reject { |k, _| k == 'project_pi_nie' }
        expect { CBGP::Dataset.load_from_params_and_write(params: params, form: 'national_regional_research_project') }
          .to raise_error(CBGP::Dataset::ValidationError) do |e|
            expect(e.errors).to contain_exactly(hash_including(label: 'PI DNI/NIE/PAS', message: 'PI DNI/NIE/PAS is required'))
          end
      end

      it 'writes successfully once every required field is supplied' do
        allow(CBGP::Dataset).to receive(:write_dataset_to_db)
        expect { CBGP::Dataset.load_from_params_and_write(params: research_params, form: 'national_regional_research_project') }
          .not_to raise_error
      end

      it 'does not require project_funding_entity, which is Personnel-only' do
        allow(CBGP::Dataset).to receive(:write_dataset_to_db)
        dataset = CBGP::Dataset.load_from_params_and_write(params: research_params, form: 'national_regional_research_project')
        expect(dataset.title).to eq('A Research Project')
      end
    end

    context 'on the Personnel form (project_funding_entity required)' do
      it 'raises ValidationError naming the funding entity when project_funding_entity is missing' do
        params = personnel_params.reject { |k, _| k == 'project_funding_entity' }
        expect { CBGP::Dataset.load_from_params_and_write(params: params, form: 'personnel_project') }
          .to raise_error(CBGP::Dataset::ValidationError) do |e|
            expect(e.errors).to contain_exactly(
              hash_including(label: 'Funding entity', message: 'Funding entity is required')
            )
          end
      end

      it 'does not require project_call_for_proposal_title, which is Research-only' do
        allow(CBGP::Dataset).to receive(:write_dataset_to_db)
        expect do
          CBGP::Dataset.load_from_params_and_write(params: personnel_params, form: 'personnel_project')
        end.not_to raise_error
      end

      it 'writes successfully once every required field is supplied' do
        allow(CBGP::Dataset).to receive(:write_dataset_to_db)
        dataset = CBGP::Dataset.load_from_params_and_write(params: personnel_params, form: 'personnel_project')
        expect(dataset.total_funding).to eq('1000.00')
      end
    end

    it 'falls back to params["database"] as the effective form when form: is not given' do
      # national_regional_research_project's dbname is "project" but its own
      # class name is what fields_for/requires-field actually key off of, so
      # this only exercises the fallback cleanly when params["database"] is
      # itself a real form class name, same as personnel_project already is
      # elsewhere in this file.
      params = research_params.reject { |k, _| k == 'project_pi_nie' }
      expect { CBGP::Dataset.load_from_params_and_write(params: params) }
        .to raise_error(CBGP::Dataset::ValidationError) do |e|
          expect(e.errors).to contain_exactly(hash_including(label: 'PI DNI/NIE/PAS', message: 'PI DNI/NIE/PAS is required'))
        end
    end
  end

  describe 'Questionnaire#required flag (drives the visual asterisk in _question.erb)' do
    def find_question(questionnaire, questionid)
      questionnaire.sections.flat_map(&:questions).find { |q| q.questionid == questionid }
    end

    it 'marks project_pi_nie required on the Research questionnaire' do
      questionnaire = Questionnaire.new(questionnaire_type: 'national_regional_research_project')
      expect(find_question(questionnaire, 'project_pi_nie').required).to be true
    end

    it 'has no personnel_project_total_funding question at all on the Research questionnaire' do
      questionnaire = Questionnaire.new(questionnaire_type: 'national_regional_research_project')
      expect(find_question(questionnaire, 'personnel_project_total_funding')).to be_nil
    end

    it 'marks project_funding_entity required on the Personnel questionnaire' do
      questionnaire = Questionnaire.new(questionnaire_type: 'personnel_project')
      expect(find_question(questionnaire, 'project_funding_entity').required).to be true
    end

    it 'has no project_call_for_proposal_title question at all on the Personnel questionnaire' do
      questionnaire = Questionnaire.new(questionnaire_type: 'personnel_project')
      expect(find_question(questionnaire, 'project_call_for_proposal_title')).to be_nil
    end

    it 'leaves every question unrequired for a form with no local:requires-field at all' do
      questionnaire = Questionnaire.new(questionnaire_type: 'member')
      expect(questionnaire.sections.flat_map(&:questions).map(&:required)).to all(be false)
    end
  end
end
