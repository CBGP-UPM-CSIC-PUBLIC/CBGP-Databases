# frozen_string_literal: true

# A field required only when ANOTHER field has a given answer
# (local:has-conditional-requirements): e.g. the dates of a project are
# required once it is Awarded, but not while it is only an application
# (Proposed) - a pending application has no dates yet. The mechanism is
# generic (any form, any field, any answer); the project forms are just where
# the ontology declares it today.
RSpec.describe 'conditional requirements' do
  before { allow(CBGP::Dataset).to receive(:get_primary_id).and_return(nil) }

  describe '.form_conditional_requirements (real ontology)' do
    it 'lists the date rules of a project form, grouped by field' do
      rules = CBGP::Dataset.form_conditional_requirements(form: 'european_research_project')

      expect(rules).to contain_exactly(
        { field: 'project_end_date', when_field: 'project_status', answers: ['Awarded'] },
        { field: 'project_start_date', when_field: 'project_status', answers: ['Awarded'] }
      )
    end

    it 'is empty for a form that declares none, and for an unknown form, rather than raising' do
      expect(CBGP::Dataset.form_conditional_requirements(form: 'member')).to eq([])
      expect(CBGP::Dataset.form_conditional_requirements(form: 'not_a_real_form')).to eq([])
    end

    it 'covers every project form, and moved the dates out of their unconditional requirements' do
      %w[european_research_project national_regional_research_project private_research_project personnel_project
         programa_propio_research_project].each do |form|
        expect(CBGP::Dataset.form_conditional_requirements(form: form).map { |r| r[:field] })
          .to contain_exactly('project_end_date', 'project_start_date')
        expect(CBGP::Dataset.form_required_fields(form: form)).not_to include('project_start_date', 'project_end_date')
      end
    end
  end

  describe '.conditional_requirement_errors (made-up rules)' do
    let(:dataset) do
      ds = CBGP::Dataset.new(type: 'personnel_project')
      ds.title = 'A Project'
      ds
    end

    def stub_rules(*rules)
      allow(CBGP::Dataset).to receive(:form_conditional_requirements).and_return(rules)
    end

    def set(qc, value)
      field = dataset.fields.find { |f| f[:questionclass] == qc }
      dataset.public_send("#{field[:method]}=", value)
    end

    it 'requires the field when the deciding field has one of the answers' do
      stub_rules(field: 'project_end_date', when_field: 'project_status', answers: %w[Awarded Withdrawn])
      set('project_status', 'Withdrawn')

      errors = CBGP::Dataset.conditional_requirement_errors(dataset: dataset, form: 'personnel_project')

      expect(errors.size).to eq(1)
      expect(errors.first[:label]).to eq('End date')
      expect(errors.first[:message]).to match(/End date is required when .* is Withdrawn/i)
    end

    it 'does not require it for any other answer, or when the deciding field is empty' do
      stub_rules(field: 'project_end_date', when_field: 'project_status', answers: ['Awarded'])
      expect(CBGP::Dataset.conditional_requirement_errors(dataset: dataset, form: 'x')).to eq([])
      set('project_status', 'Proposed')
      expect(CBGP::Dataset.conditional_requirement_errors(dataset: dataset, form: 'x')).to eq([])
    end

    it 'is satisfied once the field has a value' do
      stub_rules(field: 'project_end_date', when_field: 'project_status', answers: ['Awarded'])
      set('project_status', 'Awarded')
      set('project_end_date', '2027-01-31')
      expect(CBGP::Dataset.conditional_requirement_errors(dataset: dataset, form: 'x')).to eq([])
    end

    it 'ignores a rule naming a field the form does not have' do
      stub_rules({ field: 'no_such_field', when_field: 'project_status', answers: ['Awarded'] },
                 { field: 'project_end_date', when_field: 'no_such_field', answers: ['Awarded'] })
      set('project_status', 'Awarded')
      expect(CBGP::Dataset.conditional_requirement_errors(dataset: dataset, form: 'x')).to eq([])
    end
  end

  describe 'saving a project (real ontology)' do
    let(:params) do
      { 'database' => 'european_research_project', 'primary_id' => '',
        'project_title' => 'An Application', 'project_pi_nie' => '12345678Z',
        'project_funding_institution' => 'placeholder', 'project_affiliation' => 'affiliation_upm',
        'project_application_url' => 'https://example.org/call/TEST', 'project_call_for_proposal_title' => 'Call',
        'project_internal_code' => 'TEST-1' }
    end

    def save(extra)
      CBGP::Dataset.load_from_params_and_write(params: params.merge(extra), form: 'european_research_project')
    end

    before { allow(CBGP::Dataset).to receive(:write_dataset_to_db) }

    it 'accepts an application with no dates while it is only Proposed' do
      expect { save('project_status' => 'Proposed') }.not_to raise_error
    end

    it 'accepts a record with no status at all and no dates' do
      expect { save({}) }.not_to raise_error
    end

    it 'refuses an Awarded project with no dates, naming both and the condition' do
      expect { save('project_status' => 'Awarded') }.to raise_error(CBGP::Dataset::ValidationError) do |e|
        expect(e.errors.map { |x| x[:label] }).to contain_exactly('Start date', 'End date')
        expect(e.errors.first[:message]).to match(/required when .* is Awarded/)
      end
    end

    it 'accepts an Awarded project once both dates are given' do
      expect { save('project_status' => 'Awarded', 'project_start_date' => '2026-01-01', 'project_end_date' => '2026-12-31') }
        .not_to raise_error
    end

    it 'still enforces the unconditional requirements as before' do
      expect { CBGP::Dataset.load_from_params_and_write(params: params.reject { |k, _| k == 'project_title' }, form: 'european_research_project') }
        .to raise_error(CBGP::Dataset::ValidationError) { |e| expect(e.errors.map { |x| x[:label] }).to include('Title of the project') }
    end
  end

  describe 'the note beside the field (Questionnaire)' do
    def question(form, id)
      Questionnaire.new(questionnaire_type: form).sections.flat_map(&:questions).find { |q| q.questionid == id }
    end

    it 'says when a conditionally required field is required, without marking it always required' do
      end_date = question('european_research_project', 'project_end_date')

      expect(end_date.required).to be(false)
      expect(end_date.required_when).to eq('Required when Funding status is Awarded')
    end

    it 'has no note on an ordinary field or on a form with no conditional requirements' do
      expect(question('european_research_project', 'project_title').required_when).to be_nil
      expect(question('member', 'member_start_date').required_when).to be_nil
    end
  end
end
