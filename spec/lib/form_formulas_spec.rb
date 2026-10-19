# frozen_string_literal: true

# Covers the calculated-field mechanism (2026-07-28): a form can compute one
# of its fields from OTHER field values via the ontology's local:has-formulas
# branch (Dentaku expressions, safe/sandboxed - not Ruby eval), rather than
# asking the user to do the arithmetic themselves and type in the result.
#
# Sara's 2026-08 project-fields restructuring removed the sandbox
# project_test_* formula chain this spec used to anchor to (a deliberate
# "clean test fields" pass). While rebuilding this spec around real content,
# found (and fixed directly in the ontology, since the fix was unambiguous -
# see CBGP-Ontology commit history) three dangling formula-variable
# references that meant these formulas never actually resolved:
#   - european_research_project_overheads_formula referenced a variable name
#     that matched no real field at all (typo/naming drift).
#   - a single formula-definition resource was shared verbatim by both
#     european_research_project and private_research_project, but each
#     form's own "total overheads" input field has a different name - no
#     single variable name could ever be correct for both, so it was split
#     into two per-form formula-definition resources.
#   - national_regional_research_project's year1-4 overheads formulas
#     referenced over-prefixed variable names that matched no real field.
# A useful side effect of the european_research_project fix: total_funding
# -> total_overheads -> project_cbgp_overheads is now a genuine, real
# two-step dependency CHAIN (a calculated field whose own formula depends on
# another calculated field) - exercised directly below, no synthetic/stubbed
# formula hash needed.
RSpec.describe 'per-form calculated fields' do
  before do
    %w[project_cbgp_overheads european_research_project_total_overheads
       european_private_research_project_total_funding].each do |qc|
      field = CBGP::Dataset.fields_for('european_research_project').find { |f| f[:questionclass] == qc }
      raise "fixture ontology no longer has '#{qc}' on european_research_project - update this spec" unless field
    end
  end

  describe '#get_form_formulas_query / .form_formulas' do
    it 'resolves European Research Projects to its own formulas' do
      formulas = CBGP::Dataset.form_formulas(form: 'european_research_project')
      expect(formulas).to eq(
        'project_cbgp_overheads' => 'european_research_project_total_overheads * 0.6',
        'european_research_project_total_overheads' => 'european_private_research_project_total_funding * 0.25'
      )
    end

    it 'resolves Private Research Projects to the same shared formula for project_cbgp_overheads, independently declared' do
      formulas = CBGP::Dataset.form_formulas(form: 'private_research_project')
      expect(formulas).to eq('project_cbgp_overheads' => 'private_research_project_total_overheads * 0.6')
    end

    it 'returns an empty hash for a form with no local:has-formulas at all' do
      expect(CBGP::Dataset.form_formulas(form: 'member')).to eq({})
    end

    it 'returns an empty hash for a nonexistent form class rather than raising' do
      expect(CBGP::Dataset.form_formulas(form: 'not_a_real_form')).to eq({})
    end
  end

  describe 'Questionnaire#formula / #formula_dependencies (drives the read-only _calculated.erb widget)' do
    def find_question(questionnaire, questionid)
      questionnaire.sections.flat_map(&:questions).find { |q| q.questionid == questionid }
    end

    it "exposes European Research Projects' own formula, with correctly-extracted dependencies" do
      questionnaire = Questionnaire.new(questionnaire_type: 'european_research_project')

      total_overheads = find_question(questionnaire, 'european_research_project_total_overheads')
      expect(total_overheads.formula).to eq('european_private_research_project_total_funding * 0.25')
      expect(total_overheads.formula_dependencies).to eq(%w[european_private_research_project_total_funding])
    end

    it 'exposes the same shared formula independently on Private Research Projects' do
      questionnaire = Questionnaire.new(questionnaire_type: 'private_research_project')
      cbgp_overheads = find_question(questionnaire, 'project_cbgp_overheads')
      expect(cbgp_overheads.formula).to eq('private_research_project_total_overheads * 0.6')
      expect(cbgp_overheads.formula_dependencies).to eq(%w[private_research_project_total_overheads])
    end

    it 'has no european_research_project_total_overheads question at all on Private Research Projects' do
      questionnaire = Questionnaire.new(questionnaire_type: 'private_research_project')
      expect(find_question(questionnaire, 'european_research_project_total_overheads')).to be_nil
    end

    it 'leaves formula nil for an ordinary (non-calculated) question' do
      questionnaire = Questionnaire.new(questionnaire_type: 'european_research_project')
      expect(find_question(questionnaire, 'project_title').formula).to be_nil
    end
  end

  describe '.load_from_params_and_write calculated-field evaluation (real two-step chain)' do
    # european_research_project's real formulas (fixed above): total_funding
    # * 0.25 -> total_overheads, then total_overheads * 0.6 -> cbgp_overheads
    # - exercising evaluate_calculated_fields' actual recomputation/
    # tamper-resistance/dependency-ordering logic against real ontology
    # content, no stub needed.
    let(:base_params) do
      {
        'database' => 'european_research_project',
        'primary_id' => '',
        'project_title' => 'Chain Test Project',
        'project_funding_institution' => 'funding_institutions_european_commision',
        'project_affiliation' => 'affiliation_upm',
        'project_application_url' => 'https://example.org/call/TEST-CODE',
        'project_call_for_proposal_title' => 'Test Call',
        'project_internal_code' => 'TEST-INTERNAL',
        'project_pi_nie' => '12345678Z',
        'project_start_date' => '2026-01-01',
        'project_end_date' => '2026-12-31'
      }
    end

    before do
      allow(CBGP::Dataset).to receive(:write_dataset_to_db)
      allow(CBGP::Dataset).to receive(:get_primary_id).and_return(nil)
    end

    it 'resolves the full chain from a single submission of the base field' do
      params = base_params.merge('european_private_research_project_total_funding' => '10000.00')
      dataset = CBGP::Dataset.load_from_params_and_write(params: params, form: 'european_research_project')

      expect(dataset.total_overheads).to eq('2500.00') # 10000 * 0.25
      expect(dataset.cbgp_overheads).to eq('1500.00') # 2500  * 0.6 - depends on the line above
    end

    it 'never lets the client-submitted value for a calculated field survive - it is always server-recomputed' do
      # Tampered/forged values for the calculated fields themselves must be
      # completely ignored, since load_from_params_and_write always
      # overwrites them - this is the core trust property of the mechanism.
      params = base_params.merge(
        'european_private_research_project_total_funding' => '10000.00',
        'european_research_project_total_overheads' => '999999.99',
        'project_cbgp_overheads' => '999999.99'
      )
      dataset = CBGP::Dataset.load_from_params_and_write(params: params, form: 'european_research_project')

      expect(dataset.total_overheads).to eq('2500.00')
      expect(dataset.cbgp_overheads).to eq('1500.00')
    end

    it 'leaves the whole chain blank when the base dependency is missing, rather than raising or partially computing' do
      dataset = CBGP::Dataset.load_from_params_and_write(params: base_params, form: 'european_research_project')

      expect(dataset.total_overheads).to be_nil.or eq('')
      expect(dataset.cbgp_overheads).to be_nil.or eq('')
    end
  end
end
