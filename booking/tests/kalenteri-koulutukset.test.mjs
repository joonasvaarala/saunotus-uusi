// Hallinnan Kalenteri: koulutukset ja niiden tilavaraukset (Joonas 11.11.2026). Data: admin_event_list('training') kuten PRODissa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { calendarTrainingDays, withoutTrainingBlocks, trainingSpaceName } from '../admin/training-logic.js';

const blk = (id, code, name, s, e, extra = {}) => ({ id, mode: 'exclusive', resource_id: id + 1000, resource_code: code, resource_kind: 'space', resource_name: name, starts_at: s, ends_at: e, ...extra });
// PROD-muoto (rule 117): pe 19–22 savusauna, la ja su 9–16 Rauni.
const course = { product_id: 120, name: 'Saunottajakoulutus 2027', name_en: 'Sauna host training 2027', category: 'training', rules: [{
  id: 117, label: '1. viikonloppu 22.–24.1.2027', label_en: 'Weekend 1', active: true, cancelled_at: null,
  starts_at: '2027-01-22T17:00:00+00:00', ends_at: '2027-01-24T14:00:00+00:00',
  blocks: [blk(18, 'savusauna', 'Savusauna', '2027-01-22T17:00:00+00:00', '2027-01-22T20:00:00+00:00'),
    blk(12, 'rauni', 'Hoitosauna Rauni', '2027-01-23T07:00:00+00:00', '2027-01-23T14:00:00+00:00'),
    blk(23, 'rauni', 'Hoitosauna Rauni', '2027-01-24T07:00:00+00:00', '2027-01-24T14:00:00+00:00'),
    { id: 99, mode: 'shared', resource_id: 4, resource_code: 'saunottaja_aino', resource_kind: 'person', starts_at: '2027-01-23T07:00:00+00:00', ends_at: '2027-01-23T14:00:00+00:00' }],
}] };

test('monipäiväinen koulutus näkyy jokaisena päivänä oman päivän tiloineen', () => {
  const m = calendarTrainingDays([course], '2027-01-18', '2027-02-01');
  assert.deepEqual([...m.keys()].sort(), ['2027-01-22', '2027-01-23', '2027-01-24']);
  assert.deepEqual(m.get('2027-01-22')[0].space_names, ['Savusauna']);
  assert.deepEqual(m.get('2027-01-23')[0].space_names, ['Rauni']);
  assert.equal(m.get('2027-01-23')[0].spaces.length, 1, 'henkilöresurssi ei ole tilavaraus');
  assert.equal(m.get('2027-01-23')[0].name, 'Saunottajakoulutus 2027');
  assert.equal(m.get('2027-01-23')[0].href, '#/koulutukset?tapahtuma=120&kerta=117');
  assert.equal(calendarTrainingDays([course], '2027-01-18', '2027-02-01', { lang: 'en' }).get('2027-01-22')[0].name, 'Sauna host training 2027');
});

test('aikaväli rajaa, peruttu ja pois käytöstä oleva kerta ei näy', () => {
  assert.deepEqual([...calendarTrainingDays([course], '2027-01-23', '2027-01-24').keys()], ['2027-01-23']);
  const off = { ...course, rules: [{ ...course.rules[0], cancelled_at: '2026-12-01T00:00:00Z' }, { ...course.rules[0], id: 2, active: false }] };
  assert.equal(calendarTrainingDays([off], '2027-01-18', '2027-02-01').size, 0);
});

test('saman tuotteen päällekkäiset kerrat yhdistyvät, eri tuotteet omina riveinään; matka linkittyy Matkat-ryhmään', () => {
  const full = { product_id: 119, name: 'Full Training', category: 'training', rules: [
    { id: 111, label: 'Aloitus', active: true, starts_at: '2026-11-30T10:30:00Z', ends_at: '2026-12-13T14:00:00Z', blocks: [] },
    { id: 112, label: 'Jatkoviikko', active: true, starts_at: '2026-12-07T10:30:00Z', ends_at: '2026-12-13T14:00:00Z', training_segment_only: true, blocks: [blk(5, 'lovi', 'Hoitosauna Lovi', '2026-12-08T08:00:00Z', '2026-12-08T10:00:00Z')] }] };
  const trip = { product_id: 121, name: 'A Journey', category: 'training', rules: [{ id: 158, label: '5.–9.3.', active: true, starts_at: '2026-12-08T10:30:00Z', ends_at: '2026-12-08T15:00:00Z', blocks: [] }] };
  const d = calendarTrainingDays([full, trip], '2026-12-01', '2026-12-31').get('2026-12-08');
  assert.equal(d.length, 2);
  const f = d.find(x => x.product_id === 119);
  assert.deepEqual(f.labels, ['Aloitus', 'Jatkoviikko']);
  assert.deepEqual(f.space_names, ['Lovi']);
  assert.equal(d.find(x => x.product_id === 121).href, '#/koulutukset?ryhma=matkat&tapahtuma=121&kerta=158');
});

test('koulutuksen sulku poistuu Tilat-listasta, muut sulut jäävät', () => {
  const blocks = [{ id: 442, space_id: 1012, starts_at: '2027-01-23T07:00:00+00:00', ends_at: '2027-01-23T14:00:00+00:00', reason: 'Tapahtuma: Saunottajakoulutus 2027' },
    { id: 500, space_id: 1012, starts_at: '2027-01-23T15:00:00Z', ends_at: '2027-01-23T16:00:00Z', reason: 'Huolto' }];
  assert.deepEqual(withoutTrainingBlocks(blocks, [course]).map(b => b.id), [500]);
  assert.deepEqual(withoutTrainingBlocks(blocks, []).map(b => b.id), [442, 500]);
});

test('tilojen lyhyet nimet', () => {
  assert.equal(trainingSpaceName({ resource_code: 'hoitosauna_rauni', resource_name: 'Hoitosauna Rauni' }), 'Rauni');
  assert.equal(trainingSpaceName({ resource_code: 'savusauna' }), 'Savusauna');
  assert.equal(trainingSpaceName({ resource_code: 'x', resource_name: 'Muu tila' }), 'Muu tila');
});
